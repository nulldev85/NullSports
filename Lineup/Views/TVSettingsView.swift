import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

/// A single translucent settings surface, with stable category navigation and
/// a separately scrolling list. All actions still use their original stores.
struct AccountView: View {
    @Binding var selectedTab: Int
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(\.tvTabIsActive) private var tabIsActive
    @StateObject private var browseRows = TVLibraryBrowseRows()
    @EnvironmentObject private var cloud: CloudSettingsSync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var category: TVSettingsCategory
    @FocusState private var sidebarFocus: TVSettingsCategory?
    @Namespace private var settingsFocus
    @State private var addingProvider = false
    @State private var choosingProvider = false
    @State private var addingMediaServer = false
    @State private var configuringMDBList = false
    @State private var configuringSeerr = false
    @State private var showingTracking = false
    @State private var managingTeamChannels = false
    @State private var managingTeams = false
    @State private var choosingAccent = false
    @State private var choosingEngineFor: TVPlaybackPlace?
    @State private var showingCollections = false
    @State private var choosingShelf = false
    @State private var removingShelf = false
    @State private var reorderingShelves = false
    @State private var clearingHistory = false
    @State private var settingUpFromPhone = false
    @State private var pendingAccent: String?
    @AppStorage(TVPlaybackEngine.storageKey) private var playbackEngine = TVPlaybackEngine.vlc.rawValue
    @AppStorage(TVPlaybackPlace.sports.storageKey) private var sportsEngine = ""
    @AppStorage(TVPlaybackPlace.guide.storageKey) private var guideEngine = ""
    @AppStorage(TVPlaybackPlace.library.storageKey) private var libraryEngine = ""
    @AppStorage(TVPlaybackPlace.search.storageKey) private var searchEngine = ""
    @AppStorage(LineupAccent.storageKey) private var accentHex = LineupAccent.red.hex

    init(selectedTab: Binding<Int>, initialCategory: TVSettingsCategory = .sources) {
        _selectedTab = selectedTab
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        NavigationStack {
            settingsCanvas
            .onAppear {
                media.loadShelvesIfNeeded()
                media.loadMDBListIntegrationIfNeeded()
            }
            .onChange(of: media.profiles.map(\.id)) { _, _ in media.loadShelvesIfNeeded() }
            .tvChoices("\(choosingEngineFor?.title ?? "Playback") Engine", symbol: "play.rectangle",
                       isPresented: Binding(get: { choosingEngineFor != nil },
                                            set: { if !$0 { choosingEngineFor = nil } }),
                       message: "Used for the next stream you open in \(choosingEngineFor?.title ?? "this tab"). MPVKit is a trial; if it cannot open a stream, Lineup falls back to AetherEngine, then VLC.") {
                guard let place = choosingEngineFor else { return [] }
                return TVPlaybackEngine.allCases.map { engine in
                     TVChoice(engine.title, symbol: "play.rectangle", namesEngine: true, version: engine.version,
                              isSelected: self.engine(for: place) == engine) {
                        setEngine(engine, for: place)
                    }
                }
            }
            .tvChoices("Live TV Sources", symbol: "antenna.radiowaves.left.and.right", isPresented: $choosingProvider,
                       message: "Your provider supplies the streams. Connect its Xtream login or add an EPGenius / M3U playlist.") {
                library.profiles.map { profile in
                    TVChoice(profile.name, symbol: profile.isPlaylist ? "list.bullet.rectangle" : "server.rack",
                             id: profile.id.uuidString, isSelected: library.activeProfile?.id == profile.id) {
                        Task { await library.selectProfile(profile) }
                    }
                } + [TVChoice("Add TV Source", symbol: "plus", id: "add-provider") { addingProvider = true }]
            }
            .lineupSheet(isPresented: $addingProvider) {
                ProfileSetupView().environment(library)
            }
            .lineupSheet(isPresented: $addingMediaServer) {
                MediaServerSetupView().environment(media)
            }
            .lineupSheet(isPresented: $configuringMDBList) {
                MDBListIntegrationView().environment(media)
            }
            .lineupSheet(isPresented: $configuringSeerr) {
                NavigationStack { SeerrSettingsView().environment(media) }
            }
            .lineupFullScreenCover(isPresented: $settingUpFromPhone) {
                TVDeviceSetupView().environment(library).environment(media)
            }
            .lineupSheet(isPresented: $showingTracking) {
                NavigationStack { LibraryTrackingSettingsView().environment(media) }
            }
            .lineupFullScreenCover(isPresented: $showingCollections) { TVCollectionsScreen().environment(media) }
            .lineupSheet(isPresented: $choosingShelf) { MediaShelfPicker().environment(media) }
            .lineupSheet(isPresented: $reorderingShelves) {
                LibraryShelfOrderSheet().environment(media).preferredColorScheme(.dark)
            }
            .tvChoices("Remove a Shelf", symbol: "minus.rectangle", isPresented: $removingShelf,
                       message: "Its titles stay on your server; only the shelf leaves the Library.") {
                media.removableShelves.map { shelf in
                    TVChoice(media.shelfName(shelf), id: "remove-\(shelf.id)", isDestructive: true) {
                        media.removeShelf(shelf)
                    }
                }
            }
            .tvChoices("Clear local tracking?", symbol: "trash", isPresented: $clearingHistory,
                       message: "This removes Continue Watching and local watched status from this Apple TV.") {
                [TVChoice("Clear Local Tracking", isDestructive: true) { media.clearLocalPlayback() }]
            }
            .lineupSheet(isPresented: $managingTeamChannels) {
                TVPreferredChannelsView().environment(library)
            }
            .lineupFullScreenCover(isPresented: $managingTeams) {
                SportsTeamsSettingsView().environment(library)
            }
            .lineupFullScreenCover(isPresented: $choosingAccent, onDismiss: {
                if let hex = pendingAccent {
                    pendingAccent = nil
                    choose(hex)
                }
            }) {
                TVAccentPicker(hex: accentHex) { pendingAccent = $0 }
            }
        }
    }
    private var settingsCanvas: some View {
        GeometryReader { geometry in
            let layout = TVSettingsLayout(size: geometry.size)
            HStack(alignment: .top, spacing: 0) {
                sidebar(layout: layout)
                    .padding(.trailing, 28)
                    .frame(width: layout.sidebarWidth)
                settingsDetail(layout: layout)
                    .padding(.horizontal, 24)
                    .frame(width: layout.contentWidth)
            }
            .padding(.horizontal, layout.inset)
            .padding(.vertical, layout.verticalInset)
            .frame(maxHeight: .infinity, alignment: .top)
            .modifier(TVSettingsGlass())
            .focusScope(settingsFocus)
            .padding(.horizontal, layout.margin)
            .padding(.top, 28).padding(.bottom, 28)
        }
        .background(TVSettingsBackdrop().ignoresSafeArea())
        .foregroundStyle(TVSettingsPalette.text)
        .onChange(of: sidebarFocus) { _, value in
            guard let value, category != value else { return }
            category = value
        }
    }

    private func sidebar(layout: TVSettingsLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.sidebarSpacing) {
            Text("Settings").font(.inter(layout.sidebarTitleSize, .bold))
                .padding(.horizontal, 18).padding(.bottom, layout.compactHeight ? 20 : 30)
                .accessibilityAddTraits(.isHeader)
            ForEach(TVSettingsCategory.allCases) { item in
                let focused = sidebarFocus == item
                let selected = category == item
                Button {
                    category = item
                } label: {
                    HStack(spacing: 18) {
                        Image(systemName: item.symbol).font(.system(size: 27, weight: .regular))
                            .frame(width: 34)
                        Text(item.title).font(.inter(layout.compactHeight ? 22 : 24, .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 8)
                        Circle().fill(selected ? LineupStyle.highlight : .clear)
                            .frame(width: 6, height: 6)
                    }
                    .foregroundStyle(TVSettingsPalette.text)
                    .padding(.horizontal, 18).frame(height: layout.sidebarRowHeight)
                    .background(focused ? TVSettingsPalette.focus : (selected ? LineupStyle.selected : .clear),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .lineupFlatButton()
                .focused($sidebarFocus, equals: item)
                .prefersDefaultFocus(selected, in: settingsFocus)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("settings.category.\(item.rawValue)")
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
            }
            Spacer(minLength: 0)
        }
        .focusSection()
        .accessibilityIdentifier("settings.sidebar")
    }

    private func settingsDetail(layout: TVSettingsLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.compactHeight ? 16 : 26) {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: category.symbol).font(.system(size: 38, weight: .regular))
                    .frame(width: 44).padding(.top, 5)
                VStack(alignment: .leading, spacing: 12) {
                    Text(category.title).font(.inter(layout.compactHeight ? 36 : 44, .bold)).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Text(category.subtitle).font(.inter(layout.compactHeight ? 20 : 23))
                        .foregroundStyle(TVSettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) { categoryRows }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .id(category)
            .focusSection()
            .accessibilityIdentifier("settings.content.\(category.rawValue)")
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var categoryRows: some View {
        switch category {
        case .sources: sourceRows
        case .playback: playbackRows
        case .library: libraryRows
        case .sports: sportsRows
        case .appearance: appearanceRows
        case .cloud: cloudRows
        case .diagnostics: diagnosticsRows
        case .about: aboutRows
        }
    }

    private var sourceRows: some View {
        Group {
            TVSettingsSection("Setup")
            TVSettingsAction(symbol: "iphone", title: "Set Up with iPhone",
                             detail: "Bring providers, servers, sign-ins and settings from Lineup on your iPhone.") {
                settingUpFromPhone = true
            }
            TVSettingsSection("Live TV")
            if let profile = library.activeProfile {
                TVSettingsInfo(symbol: "antenna.radiowaves.left.and.right", title: profile.name,
                               value: library.channelsAreSyncing ? "Updating" : (library.streams.isEmpty ? "Offline" : "Connected"))
                TVSettingsInfo(symbol: "person.crop.circle", title: profile.username,
                               value: URL(string: profile.serverURL)?.host ?? profile.serverURL)
                TVSettingsInfo(symbol: "tv", title: "Channels", value: library.streams.count.formatted())
                TVSettingsInfo(symbol: "star", title: "Favorites", value: library.favoriteStreamOrder.count.formatted())
                TVSettingsInfo(symbol: "sportscourt", title: "Saved Team Channels", value: library.teamPreferences.count.formatted())
                if let date = library.lastRefreshedAt {
                    TVSettingsInfo(symbol: "clock", title: "Last Refreshed", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if library.activeProfile == nil {
                TVSettingsAction(symbol: "plus", title: "Add TV Source",
                                 detail: "Connect your provider or add an EPGenius / M3U playlist.") { addingProvider = true }
            } else {
                TVSettingsAction(symbol: "antenna.radiowaves.left.and.right", title: "Live TV Sources",
                                 detail: "Add an EPGenius / M3U playlist or switch saved connections.",
                                 value: "\(library.profiles.count) saved") { choosingProvider = true }
                    .disabled(library.isSwitchingProfile)
            }
            if library.activeProfile != nil {
                TVSettingsAction(symbol: "arrow.clockwise", title: "Refresh Live TV",
                                 detail: "Update the current provider’s channels and TV listings.") { Task { await library.reload() } }
                    .disabled(library.channelsAreSyncing || library.isSwitchingProfile)
                TVSettingsAction(symbol: "list.bullet.rectangle", title: "Open TV Guide",
                                 detail: "Browse channels and listings from your connected TV source.") { selectedTab = 1 }
                TVSettingsAction(symbol: "trash", title: "Remove TV Source",
                                 detail: "Remove the active provider from this Apple TV.", destructive: true) { library.removeActiveProfile() }
            }
            TVSettingsSection("Media Servers")
            if media.profiles.isEmpty {
                TVSettingsInfo(symbol: "server.rack", title: "Media Server", value: "Not connected")
            }
            ForEach(media.profiles) { profile in
                TVSettingsInfo(symbol: "server.rack", title: profile.name, value: profile.displayHost)
                TVSettingsInfo(symbol: "checkmark.circle", title: "Connection", value: serverStatus(profile))
                TVSettingsAction(symbol: "trash", title: "Remove \(profile.name)",
                                 detail: "Remove this connection. Your server and its media are not deleted.", destructive: true) { media.remove(profile) }
            }
            if !media.profiles.isEmpty {
                TVSettingsInfo(symbol: "film", title: "Movies", value: media.libraryCounts.map { $0.movies.formatted() } ?? "—")
                TVSettingsInfo(symbol: "tv", title: "Shows", value: media.libraryCounts.map { $0.shows.formatted() } ?? "—")
                TVSettingsInfo(symbol: "play.rectangle", title: "Episodes", value: media.libraryCounts.map { $0.episodes.formatted() } ?? "—")
                if let date = media.lastRefreshedAt {
                    TVSettingsInfo(symbol: "clock", title: "Last Refreshed", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                TVSettingsAction(symbol: "arrow.clockwise", title: "Reload Media Servers",
                                 detail: "Fetch your servers’ libraries again.") { Task { await media.reload() } }
                    .disabled(media.isLoading)
                TVSettingsAction(symbol: "square.grid.2x2", title: "Browse Library",
                                 detail: "Open the Library tab with all your connected sources.") { selectedTab = 2 }
            }
            TVSettingsAction(symbol: "plus", title: "Add Media Server",
                             detail: "Connect your Jellyfin, Emby, Plex or another supported server.") { addingMediaServer = true }
        }
    }

    private var playbackRows: some View {
        Group {
            TVSettingsSection("Playback Engines")
            ForEach(TVPlaybackPlace.allCases) { place in
                TVSettingsAction(symbol: place.symbol, title: place.title, detail: place.detail,
                                 value: engine(for: place).title) { choosingEngineFor = place }
                    .accessibilityIdentifier("settings.engine.\(place.rawValue)")
            }
        }
    }

    private var libraryRows: some View {
        Group {
            TVSettingsSection("Browsing")
            TVSettingsLink(symbol: "sparkles.rectangle.stack", title: "Library Hero",
                           detail: "Choose the catalog shown across the top of Library.",
                           value: media.heroCatalogTitle ?? "Choose Catalog") { LibraryHeroSettingsView().environment(media) }
                .disabled(!media.hasAnySource)
            TVSettingsLink(symbol: "text.book.closed", title: "Metadata",
                           detail: "Choose the sources for movie, show and episode information.",
                           value: media.metadataSource.title) { LibraryMetadataSettingsView().environment(media) }
            TVSettingsAction(symbol: "folder", title: "Collections", detail: "Group titles your own way.",
                             value: media.personalCollections.count.formatted()) { showingCollections = true }
            TVSettingsAction(symbol: "plus.rectangle.on.rectangle", title: "Add Shelf",
                             detail: "Add a library, genre or list as a row.") { choosingShelf = true }
                .disabled(!media.hasAnySource)
            TVSettingsAction(symbol: "minus.rectangle", title: "Remove a Shelf",
                             detail: "Its titles stay on your server; only the shelf leaves the Library.",
                             value: media.removableShelves.count.formatted()) { removingShelf = true }
                .disabled(media.removableShelves.isEmpty)
            TVSettingsAction(symbol: "arrow.up.arrow.down", title: "Edit Shelves",
                             detail: "Put the Library’s rows in order.") { reorderingShelves = true }
                .disabled(media.libraryRows.count < 2)
            TVSettingsSection("Connected Services")
            TVSettingsAction(symbol: "tray.and.arrow.down", title: "Seerr",
                             detail: "Connect your request server to discover, request and manage titles.",
                             value: media.seerr.isConnected ? "Connected" : "Not connected") { configuringSeerr = true }
            TVSettingsAction(symbol: "rectangle.stack.badge.play", title: "MDBList",
                             detail: "Use your movie and show lists as Library shelves.",
                             value: media.mdbListAccount.map { "@\($0.username)" } ?? (media.isMDBListConnected ? "Connected" : "Not connected")) {
                configuringMDBList = true
            }
            if media.isMDBListConnected {
                TVSettingsInfo(symbol: "checkmark.circle", title: "Status", value: media.isMDBListLoading ? "Updating" : "Connected")
                TVSettingsInfo(symbol: "rectangle.stack", title: "Catalogs", value: media.mdbListCatalogs.count.formatted())
                TVSettingsInfo(symbol: "number", title: "Requests Left", value: media.mdbListAccount?.requestsRemaining.map { $0.formatted() } ?? "—")
                TVSettingsInfo(symbol: "calendar", title: "Daily Limit", value: media.mdbListAccount?.dailyLimit.map { $0.formatted() } ?? "—")
                TVSettingsInfo(symbol: "person.crop.circle", title: "Plan", value: media.mdbListAccount?.plan ?? "Connected")
                TVSettingsAction(symbol: "arrow.clockwise", title: "Refresh MDBList",
                                 detail: "Update your available catalogs and account information.") { Task { await media.loadMDBListIntegration() } }
                    .disabled(media.isMDBListLoading)
            }
            TVSettingsSection("Watch History")
            TVSettingsAction(symbol: "checkmark.circle", title: "Watch Tracking",
                             detail: "Choose local tracking, MDBList, both, or neither.") { showingTracking = true }
            TVSettingsAction(symbol: "arrow.clockwise", title: "Refresh Library",
                             detail: "Fetch every server’s shelves again.", value: media.isLoading ? "Updating" : nil) { Task { await media.reload() } }
                .disabled(!media.hasAnySource || media.isLoading)
            TVSettingsAction(symbol: "trash", title: "Clear Local Tracking",
                             detail: "Remove Continue Watching and local watched status from this Apple TV.", destructive: true) { clearingHistory = true }
                .disabled(!hasLocalTrackingRecords)
        }
    }

    private var hasLocalTrackingRecords: Bool {
        let snapshot = browseRows.snapshot(in: media, active: tabIsActive && category == .library)
        return !snapshot.continuing.isEmpty || snapshot.hasHistory
    }

    private var sportsRows: some View {
        Group {
            TVSettingsSection("Your Teams")
            TVSettingsAction(symbol: "star", title: "Follow Your Teams",
                             detail: "Follow teams in NFL, NBA, NHL, MLB and college football.",
                             value: "\(library.followedTeams.count) following") { managingTeams = true }
            if library.activeProfile != nil {
                TVSettingsAction(symbol: "star.square.on.square", title: "Preferred Channels",
                                 detail: "Manage the channels saved for your teams. Hold Select on a game to save a different channel.",
                                 value: "\(library.teamPreferences.count) saved") { managingTeamChannels = true }
            }
        }
    }

    private var appearanceRows: some View {
        let chosen = LineupAccent.accent(forHex: accentHex)
        return Group {
            TVSettingsSection("Color")
            TVSettingsAction(symbol: "paintpalette", title: "Accent Color",
                             detail: "Choose from presets, custom colors and My Colors.",
                             value: chosen.isPreset ? chosen.name : "#\(chosen.hex)") { choosingAccent = true }
        }
    }

    private var cloudRows: some View {
        Group {
            TVSettingsSection("Settings Sync")
            TVSettingsInfo(symbol: "icloud", title: "iCloud", value: cloud.status)
            Text("Lineup keeps your sources, favorites, teams and appearance settings in your private iCloud account.")
                .font(.inter(22)).foregroundStyle(TVSettingsPalette.secondary).lineSpacing(6)
                .padding(.horizontal, 18).padding(.top, 22)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diagnosticsRows: some View {
        Group {
            TVSettingsSection("Activity")
            TVSettingsLink(symbol: "point.3.connected.trianglepath.dotted", title: "Channel Matching",
                           detail: "See why each game chose its channel.") { MatchDiagnosticsView() }
            TVSettingsLink(symbol: "speedometer", title: "Launch Timing",
                           detail: "See where the last start spent its time.") { TVStartupTraceView() }
            TVSettingsLink(symbol: "list.bullet.rectangle.portrait", title: "Playback Log",
                           detail: "See what the player did and why it stopped.") { TVPlaybackJournalView() }
        }
    }

    private var aboutRows: some View {
        Group {
            TVSettingsSection("Lineup")
            TVSettingsInfo(symbol: "app", title: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            TVSettingsInfo(symbol: "number", title: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            TVSettingsLink(symbol: "doc.text", title: "Playback Acknowledgements",
                           detail: "AetherEngine, MPVKit and decoder licenses.") { TVPlaybackLicensesView() }
        }
    }

    private func serverStatus(_ profile: MediaServerProfile) -> String {
        let state = media.state(of: profile)
        if state.isLoading { return "Connecting" }
        guard state.isConnected else { return "Offline" }
        guard let counts = state.counts else { return "Connected" }
        return "\(counts.movies.formatted()) movies · \(counts.shows.formatted()) shows"
    }

    private func engine(for place: TVPlaybackPlace) -> TVPlaybackEngine {
        let own = switch place {
        case .sports: sportsEngine
        case .guide: guideEngine
        case .library: libraryEngine
        case .search: searchEngine
        }
        return TVPlaybackEngine(rawValue: own) ?? TVPlaybackEngine(rawValue: playbackEngine) ?? .vlc
    }

    private func setEngine(_ engine: TVPlaybackEngine, for place: TVPlaybackPlace) {
        switch place {
        case .sports: sportsEngine = engine.rawValue
        case .guide: guideEngine = engine.rawValue
        case .library: libraryEngine = engine.rawValue
        case .search: searchEngine = engine.rawValue
        }
    }

    private func choose(_ hex: String) {
        guard hex != accentHex else { return }
        accentHex = hex
        CloudSettingsSync.shared.localSettingsChanged()
    }
}

private struct TVPreferredChannelsView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting: TeamChannelEntry?
    @State private var clearingAll = false

    var body: some View {
        let entries = library.teamPreferences.listed()
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageTitle(eyebrow: "Settings", title: "Preferred Channels",
                          detail: "Games for these teams open on the channel saved for them. If it is unavailable, Lineup uses its own match and keeps the preference.")
                if entries.isEmpty {
                    Text("No preferred channels yet. Hold Select on any game, pick Choose Another Channel, and Lineup can remember it for either team.")
                        .font(.inter(22)).foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 12) {
                        ForEach(entries) { entry in
                            TVSelectable(scale: 1.01, fillRadius: 16, action: { forgetting = entry },
                                         requestInitialFocus: entry.id == entries.first?.id) {
                                row(entry)
                            }
                        }
                    }
                }
                HStack(spacing: 20) {
                    if !entries.isEmpty {
                        Button("Remove All", role: .destructive) { clearingAll = true }
                    }
                    Button("Done") { dismiss() }
                }
                .lineupButtonStyle()
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 56)
        }
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .tvChoices("Forget this channel?", symbol: "trash",
                   isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                   message: forgetting.map { "\(name(of: $0)) games will open on Lineup's own match again." }) {
            guard let entry = forgetting else { return [] }
            return [TVChoice("Forget", isDestructive: true) {
                library.removePreference(for: entry.key)
                forgetting = nil
            }]
        } onCancel: { forgetting = nil }
        .tvChoices("Remove every preferred channel?", symbol: "trash", isPresented: $clearingAll,
                   message: "This clears the saved channels for \(library.activeProfile?.name ?? "this provider") only.") {
            [TVChoice("Remove All", isDestructive: true) { library.removeAllPreferences() }]
        }
    }

    private func name(of entry: TeamChannelEntry) -> String {
        entry.preference.teamName.isEmpty ? entry.key.team : entry.preference.teamName
    }

    private func row(_ entry: TeamChannelEntry) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(name(of: entry)).font(.inter(26, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                HStack(spacing: 10) {
                    Text(entry.preference.channelName)
                        .font(.inter(20)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                    // A provider can drop a channel and carry it again later,
                    // so this is a note, not a reason to delete the preference.
                    if !library.preferenceChannelIsAvailable(entry.preference) {
                        Text("UNAVAILABLE")
                            .font(.inter(13, .bold)).tracking(0.8)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(LineupPresentationStyle.row, in: Capsule())
                            .foregroundStyle(LineupPresentationStyle.secondary)
                    }
                }
            }
            Spacer(minLength: 16)
            Text(entry.key.league.uppercased())
                .font(.inter(16, .bold)).tracking(1.2).foregroundStyle(LineupPresentationStyle.secondary)
            Image(systemName: "trash")
                .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.secondary)
        }
        .padding(.horizontal, 28)
        .frame(height: 96)
        .background(LineupPresentationStyle.card, in: shape)
        .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Forget this team's channel")
    }
}


/// The last launch, step by step -- the same trace the phone shows.
///
/// It was being recorded on the television all along and thrown away, because
/// only the phone had a screen to read it on. Which meant the one question
/// worth asking about a slow start on a set -- which part is slow -- could
/// only be guessed at, and guessing is what cost days on the phone.
private struct TVStartupTraceView: View {
    @ObservedObject private var trace = StartupTrace.shared

    var body: some View {
        ScrollView {
            Text(trace.report)
                .font(.interDigits(21))
                .foregroundStyle(LineupPresentationStyle.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(40)
        }
        .focusable()
        .background(LineupPresentationStyle.ground)
    }
}

/// What the player did, newest first, on the television itself: the trail a
/// film that stopped on its own leaves behind, read without a device log.
private struct TVPlaybackJournalView: View {
    @ObservedObject private var journal = PlaybackJournal.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                ScreenHeading(title: "Playback log", detail: "What the player did and why it stopped, newest first")
                Spacer()
                Button("Clear") { journal.clear() }
                    .lineupButtonStyle()
                    .disabled(journal.entries.isEmpty)
            }
            if journal.entries.isEmpty {
                Text("Nothing has played since the log was cleared.")
                    .font(.inter(.title3)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(journal.days) { day in
                        Text(day.name.uppercased())
                            .font(.inter(13, .heavy)).tracking(0.6)
                            .foregroundStyle(LineupPresentationStyle.secondary)
                            .padding(.top, 18)
                        ForEach(Array(day.entries.enumerated()), id: \.offset) { _, entry in
                            TVPlaybackJournalRow(entry: entry)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 120).padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground)
    }
}

/// One thing the player did: the time, then what.
private struct TVPlaybackJournalRow: View {
    @FocusState private var focused: Bool
    let entry: PlaybackJournal.Entry

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(PlaybackJournal.time(of: entry))
                .font(.interDigits(19, .semibold))
                .foregroundStyle(LineupPresentationStyle.secondary)
            Text(entry.text)
                .font(.inter(21))
                .foregroundStyle(LineupPresentationStyle.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(LineupPresentationStyle.card, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .contentShape(shape)
        .focusable().focused($focused).focusEffectDisabled()
        .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                ScreenHeading(title: "Channel matching", detail: "The rule that chose each game's channel")
                Spacer()
            }
            if games.isEmpty {
                Text("No live or upcoming games to match.").foregroundStyle(LineupPresentationStyle.text)
                    .font(.inter(.title3)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(games) { MatchDiagnosticsRow(game: $0) }
                }.padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 120).padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground)
    }
}

private struct MatchDiagnosticsRow: View {
    @Environment(SportsLibrary.self) private var library
    @FocusState private var focused: Bool
    let game: SportsGame

    private var stream: XtreamStream? { library.stream(for: game) }
    private var evidence: SportsLibrary.MatchEvidence? { library.matchEvidence(for: game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(game.matchupLine).foregroundStyle(LineupPresentationStyle.text)
                .font(.inter(24, .semibold))
            Text("\(game.league.shortName)  ·  \(game.broadcast.isEmpty ? "No network listed" : game.broadcast)")
                .foregroundStyle(LineupPresentationStyle.text)
                .font(.inter(16)).foregroundStyle(LineupPresentationStyle.secondary)
            if let stream {
                Text(stream.name).foregroundStyle(LineupPresentationStyle.text)
                    .font(.inter(17, .medium)).lineLimit(1)
                if let rejection = library.playbackRejection(for: game) {
                    Text(rejection.rawValue).foregroundStyle(LineupStyle.warning).font(.inter(15))
                } else {
                    Text(evidence?.rawValue ?? "Matched earlier, evidence not recorded yet")
                        .foregroundStyle(evidence == .dedicatedFeed ? LineupPresentationStyle.text : LineupStyle.warning)
                        .font(.inter(15))
                }
            } else {
                Text("No match — opens the channel picker").foregroundStyle(LineupPresentationStyle.text)
                    .font(.inter(15)).foregroundStyle(LineupPresentationStyle.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusable().focused($focused).focusEffectDisabled()
        .accessibilityElement(children: .combine)
    }
}
