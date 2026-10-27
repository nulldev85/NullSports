import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

/// The Account screen: what the app is connected to, and how it is doing.
///
/// Two sources side by side -- the provider that fills Live and the Guide, and
/// the media server behind Library -- each a card that says what it is,
/// whether it answers, what it holds and what can be done with it. Below them
/// the library, diagnostics and the app itself, on the same two columns, so
/// every edge on the screen lines up with another.
struct AccountView: View {
    @Binding var selectedTab: Int
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @EnvironmentObject private var cloud: CloudSettingsSync
    @State private var addingProvider = false
    @State private var choosingProvider = false
    @State private var addingMediaServer = false
    @State private var configuringMDBList = false
    @State private var configuringSeerr = false
    @State private var showingTracking = false
    @State private var managingTeamChannels = false
    @State private var managingTeams = false
    @State private var choosingAccent = false
    /// The tab whose playback engine is being chosen.
    @State private var choosingEngineFor: TVPlaybackPlace?
    // What the Library tab's menu used to offer, now in Library below.
    @State private var showingCollections = false
    @State private var choosingShelf = false
    @State private var removingShelf = false
    @State private var reorderingShelves = false
    @State private var clearingHistory = false
    @State private var settingUpFromPhone = false
    @AppStorage(TVPlaybackEngine.storageKey) private var playbackEngine = TVPlaybackEngine.vlc.rawValue
    // Each tab's own engine: empty until one is chosen, and the tab then
    // plays with the one above, which every tab used before they had their own.
    @AppStorage(TVPlaybackPlace.sports.storageKey) private var sportsEngine = ""
    @AppStorage(TVPlaybackPlace.guide.storageKey) private var guideEngine = ""
    @AppStorage(TVPlaybackPlace.library.storageKey) private var libraryEngine = ""
    @AppStorage(TVPlaybackPlace.search.storageKey) private var searchEngine = ""
    @State private var pendingAccent: String?
    /// The accent, chosen here too: iCloud brings the phone's choice over
    /// once it is switched on, and until then the two are set by hand.
    @AppStorage(LineupAccent.storageKey) private var accentHex = LineupAccent.red.hex

    private let columnWidth: CGFloat = 1400
    private let gutter: CGFloat = 24

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 56) {
                    header
                    // Each section a panel, as on the phone: the header
                    // and its hairline inside, the cards a step lighter.
                    setUpFromPhone.modifier(TVSettingsPanel())
                    sources.modifier(TVSettingsPanel())
                    teamsSettings.modifier(TVSettingsPanel())
                    libraryAndCatalogs.modifier(TVSettingsPanel())
                    appearance.modifier(TVSettingsPanel())
                    playbackSettings.modifier(TVSettingsPanel())
                    diagnostics.modifier(TVSettingsPanel())
                    about.modifier(TVSettingsPanel())
                }
                .frame(width: columnWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
            }
            .background(LineupPresentationStyle.ground)
            // The store decides and the store owns it, as on the Media
            // Servers tab: a load tied to this screen was cancelled by
            // leaving it, and left the flag raised behind.
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LINEUP")
                .font(.inter(13, .heavy)).tracking(0.6)
                .foregroundStyle(LineupPresentationStyle.secondary)
            Text("Settings")
                .font(.inter(52, .bold))
                .foregroundStyle(LineupPresentationStyle.text)
            Text("Your sources, your library, and how the app is running.")
                .font(.inter(21))
                .foregroundStyle(LineupPresentationStyle.secondary)
        }
    }

    // MARK: Set up

    /// Everything on the phone, brought over by scanning a code.
    private var setUpFromPhone: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("IPHONE")
            AccountActionRow(symbol: "iphone", title: "Set Up with iPhone",
                             detail: "Bring providers, servers, sign-ins and settings from Lineup on your iPhone") {
                settingUpFromPhone = true
            }
        }
    }

    // MARK: Live TV

    /// The IPTV side. The media servers are under Library, with the rest of
    /// what the Library tab is made from.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("LIVE TV")
            providerCard
                .fixedSize(horizontal: false, vertical: true)
            if library.activeProfile != nil {
                providersRow
                preferredChannelsRow
            }
        }
    }

    /// Adding a provider remains available after first setup. New connections
    /// are saved alongside the active one and can be selected from this menu.
    private var providersRow: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return TVSelectable(scale: 1.01, fillRadius: 18, action: { choosingProvider = true }) {
            HStack(spacing: 20) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.text)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live TV Sources").font(.inter(24, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    Text("Add an EPGenius / M3U playlist or switch saved connections")
                        .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                Text("\(library.profiles.count) saved")
                    .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(.horizontal, 30)
            .frame(height: 96)
            .background(LineupPresentationStyle.row, in: shape)
        }
        .disabled(library.isSwitchingProfile)
    }

    /// The channels saved for teams, one press from their list.
    private var preferredChannelsRow: some View {
        let count = library.teamPreferences.count
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return TVSelectable(scale: 1.01, fillRadius: 18, action: { managingTeamChannels = true }) {
            HStack(spacing: 20) {
                Image(systemName: "star.square.on.square")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.text)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preferred Channels").font(.inter(24, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(count == 0
                         ? "None yet. Hold Select on a game and pick Choose Another Channel to save one for a team."
                         : "\(count) \(count == 1 ? "team opens" : "teams open") on a saved channel")
                        .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(.horizontal, 30)
            .frame(height: 96)
            .background(LineupPresentationStyle.row, in: shape)
        }
    }

    @ViewBuilder private var providerCard: some View {
        if let profile = library.activeProfile {
            AccountSourceCard(
                symbol: "antenna.radiowaves.left.and.right",
                kind: profile.isPlaylist ? "PLAYLIST & GUIDE" : "IPTV PROVIDER",
                title: profile.name,
                subtitle: "\(profile.username) · \(URL(string: profile.serverURL)?.host ?? profile.serverURL)",
                status: library.channelsAreSyncing ? .busy("Updating")
                    : (library.streams.isEmpty ? .offline : .connected),
                stats: [
                    AccountStat("Channels", library.streams.count),
                    AccountStat("Favorites", library.favoriteStreamOrder.count),
                    AccountStat("Teams", library.teamPreferences.listed().count)
                ],
                refreshed: library.lastRefreshedAt
            ) {
                AccountButton(title: "Refresh", symbol: "arrow.clockwise") {
                    Task { await library.reload() }
                }
                .disabled(library.channelsAreSyncing || library.isSwitchingProfile)
                AccountButton(title: "TV Guide", symbol: "list.bullet.rectangle") { selectedTab = 1 }
                AccountButton(title: "Remove", symbol: "trash", quiet: true) {
                    library.removeActiveProfile()
                }
            }
        } else {
            AccountEmptySource(
                symbol: "antenna.radiowaves.left.and.right",
                kind: "LIVE TV SOURCE",
                title: "No TV source",
                detail: "Connect your provider or add an EPGenius / M3U playlist."
            ) {
                // The first-run screen is the only other place to sign in, and
                // it never returns once a media server is saved.
                AccountButton(title: "Add TV Source", symbol: "plus", prominent: true) {
                    addingProvider = true
                }
            }
        }
    }

    @ViewBuilder private var mediaCard: some View {
        if let profile = media.profiles.first {
            let several = media.profiles.count > 1
            AccountSourceCard(
                symbol: "play.square.stack",
                brand: MediaServerBrand.shared(by: media.profiles),
                kind: several ? "MEDIA SERVERS" : "MEDIA SERVER",
                title: several ? "\(media.profiles.count) media servers" : profile.name,
                subtitle: several
                    ? media.profiles.map(\.name).joined(separator: " · ")
                    : "\(profile.username) · \(profile.displayHost)",
                status: media.isLoading ? .busy("Connecting") : (media.isConnected ? .connected : .offline),
                stats: [
                    AccountStat("Movies", media.libraryCounts?.movies),
                    AccountStat("Shows", media.libraryCounts?.shows),
                    AccountStat("Episodes", media.libraryCounts?.episodes)
                ],
                refreshed: media.lastRefreshedAt
            ) {
                AccountButton(title: "Reload", symbol: "arrow.clockwise") {
                    Task { await media.reload() }
                }
                .disabled(media.isLoading)
                AccountButton(title: "Browse", symbol: "square.grid.2x2") { selectedTab = 2 }
                AccountButton(title: "Add", symbol: "plus") { addingMediaServer = true }
                if media.profiles.count == 1 {
                    AccountButton(title: "Remove", symbol: "trash", quiet: true) {
                        media.remove(profile)
                    }
                }
            }
        } else {
            AccountEmptySource(
                symbol: "play.square.stack",
                kind: "MEDIA SERVER",
                title: "No media server",
                detail: "Connect your Jellyfin, Emby or Plex server to watch your own library."
            ) {
                AccountButton(title: "Add Media Server", symbol: "plus", prominent: true) {
                    addingMediaServer = true
                }
            }
        }
    }

    private var teamsSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("MY TEAMS")
            TVSelectable(scale: 1.01, fillRadius: 18, action: { managingTeams = true }) {
                HStack(spacing: 20) {
                    LineupIconTile(symbol: "star.fill", size: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Follow Your Teams").font(.inter(24, .semibold))
                        Text("NFL, NBA, NHL, MLB, and college football")
                            .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                    }
                    Spacer()
                    Text("\(library.followedTeams.count) following")
                        .font(.inter(21, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                    Image(systemName: "chevron.right").font(.inter(20, .semibold))
                }
                .padding(24)
                .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    // MARK: Library

    /// Everything the Library tab is made from and everything done to it:
    /// its servers and lists, its hero and metadata, and what its menu used
    /// to offer -- shelves, collections, refreshing, local tracking.
    private var libraryAndCatalogs: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("LIBRARY")
            HStack(alignment: .top, spacing: gutter) {
                mediaCard
                catalogs
            }
            .fixedSize(horizontal: false, vertical: true)
            // Every server feeds the Library at once, so with more than one
            // the card above speaks for all of them and this list for each:
            // whether it answers, what it holds, and the way to remove it.
            if media.profiles.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(media.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 {
                            Rectangle().fill(LineupStyle.line).frame(height: 1).padding(.horizontal, 30)
                        }
                        AccountServerRow(profile: profile)
                    }
                }
                .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            HStack(alignment: .top, spacing: gutter) {
                AccountLinkCard(
                    symbol: "sparkles.rectangle.stack",
                    kind: "LIBRARY",
                    title: "Library Hero",
                    detail: media.heroCatalog.map { "Top 10 from \($0.title)" }
                        ?? "Choose the catalog shown across the top of Library",
                    action: "Choose Catalog",
                    actionSymbol: "slider.horizontal.3"
                ) {
                    LibraryHeroSettingsView().environment(media)
                }
                .disabled(!media.hasAnySource)
                AccountLinkCard(
                    symbol: "text.book.closed", kind: "LIBRARY", title: "Metadata",
                    detail: "Movies and shows: \(media.metadataSource.title) · Episodes: \(media.episodeDataSource.title)",
                    action: "Choose Sources", actionSymbol: "slider.horizontal.3"
                ) {
                    LibraryMetadataSettingsView().environment(media)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            libraryActions
        }
    }

    /// What the Library tab's menu offered, two to a row. One that has
    /// nothing to act on stays in its place, dimmed, so the rest never move.
    private var libraryActions: some View {
        let own = media.personalCollections.count
        let removable = media.removableShelves.count
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: gutter), GridItem(.flexible())],
                         alignment: .leading, spacing: gutter) {
            AccountActionRow(symbol: "checkmark.circle", title: "Watch Tracking",
                             detail: "Choose local tracking, MDBList, both, or neither") { showingTracking = true }
            AccountActionRow(symbol: "tray.and.arrow.down", title: "Seerr",
                             detail: media.seerr.isConnected ? "Discover, request and manage titles" : "Connect your request server") { configuringSeerr = true }
            AccountActionRow(symbol: "folder.fill", title: "Collections",
                             detail: own == 0 ? "Group titles your own way" : "\(own) of your own") {
                showingCollections = true
            }
            AccountActionRow(symbol: "plus.rectangle.on.rectangle", title: "Add Shelf",
                             detail: "A library, genre or list as a row") { choosingShelf = true }
                .disabled(!media.hasAnySource)
            AccountActionRow(symbol: "minus.rectangle", title: "Remove a Shelf",
                             detail: removable == 0 ? "No shelves to remove"
                                : "\(removable) \(removable == 1 ? "shelf" : "shelves") on the Library tab") {
                removingShelf = true
            }
            .disabled(removable == 0)
            AccountActionRow(symbol: "arrow.up.arrow.down", title: "Edit Shelves",
                             detail: "Put the Library's rows in order") { reorderingShelves = true }
                .disabled(media.libraryRows.count < 2)
            AccountActionRow(symbol: "arrow.clockwise", title: "Refresh Library",
                             detail: media.isLoading ? "Updating…" : "Fetch every server's shelves again") {
                Task { await media.reload() }
            }
            .disabled(!media.hasAnySource || media.isLoading)
            AccountActionRow(symbol: "trash", title: "Clear Local Tracking",
                             detail: "Continue Watching and watched marks here", destructive: true) {
                clearingHistory = true
            }
            .disabled(media.continueWatching.isEmpty && media.watchHistory.isEmpty)
        }
    }

    /// MDBList, which turns the viewer's lists into Library shelves.
    @ViewBuilder private var catalogs: some View {
        if media.isMDBListConnected {
            let account = media.mdbListAccount
            AccountSourceCard(
                symbol: "rectangle.stack.badge.play",
                kind: "CATALOGS",
                title: "MDBList",
                subtitle: account.map { "@\($0.username) · \($0.plan ?? "Connected")" } ?? "Catalog discovery",
                status: media.isMDBListLoading ? .busy("Updating") : .connected,
                stats: [
                    AccountStat("Catalogs", media.mdbListCatalogs.count),
                    AccountStat("Requests Left", account?.requestsRemaining),
                    AccountStat("Daily Limit", account?.dailyLimit)
                ],
                refreshed: nil
            ) {
                AccountButton(title: "Configure", symbol: "gearshape") { configuringMDBList = true }
                AccountButton(title: "Refresh", symbol: "arrow.clockwise") {
                    Task { await media.loadMDBListIntegration() }
                }
                .disabled(media.isMDBListLoading)
            }
        } else {
            AccountEmptySource(
                symbol: "rectangle.stack.badge.play",
                kind: "CATALOGS",
                title: "MDBList",
                detail: "Connect MDBList to use your movie and show lists as Library shelves."
            ) {
                AccountButton(title: "Connect MDBList", symbol: "link", prominent: true) {
                    configuringMDBList = true
                }
            }
        }
    }

    // MARK: Diagnostics and about

    /// The two screens that answer "why did it do that", side by side.
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("DIAGNOSTICS")
            HStack(alignment: .top, spacing: gutter) {
                AccountTile(title: "Channel matching", detail: "Why each game chose its channel",
                            symbol: "point.3.connected.trianglepath.dotted") { MatchDiagnosticsView() }
                AccountTile(title: "Launch timing", detail: "Where the last start spent its time",
                            symbol: "speedometer") { TVStartupTraceView() }
                AccountTile(title: "Playback log", detail: "What the player did, and why it stopped",
                            symbol: "list.bullet.rectangle.portrait") { TVPlaybackJournalView() }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Appearance

    /// A playback engine for each tab that plays video: a source one engine
    /// struggles with can play on the other without moving everything.
    private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("PLAYBACK")
            Text("Each tab plays with its own engine.")
                .font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary)
            VStack(spacing: 14) {
                ForEach(TVPlaybackPlace.allCases) { place in
                    AccountEngineRow(place: place, engine: engine(for: place)) { choosingEngineFor = place }
                }
            }
        }
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

    /// Opens the same preset, custom and saved color choices as the phone.
    private var appearance: some View {
        let chosen = LineupAccent.accent(forHex: accentHex)
        return VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("APPEARANCE")
            TVSelectable(scale: 1.015, fillRadius: 18, action: { choosingAccent = true }) {
                HStack(spacing: 20) {
                    Circle().fill(chosen.color).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accent Color").font(.inter(24, .semibold))
                        Text("Presets, custom colors, and My Colors")
                            .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                    }
                    Spacer()
                    Text(chosen.isPreset ? chosen.name : "#\(chosen.hex)")
                        .font(.inter(21, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                    Image(systemName: "chevron.right").font(.inter(20, .semibold))
                }
                .padding(24)
                .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func choose(_ hex: String) {
        guard hex != accentHex else { return }
        accentHex = hex
        CloudSettingsSync.shared.localSettingsChanged()
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("ABOUT")
            HStack(spacing: gutter) {
                AccountRow(label: "iCloud", value: cloud.status)
                AccountRow(label: "Version",
                           value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1")
            }
            AccountTile(title: "Playback acknowledgements", detail: "AetherEngine, MPVKit, and decoder licenses",
                        symbol: "doc.text") { TVPlaybackLicensesView() }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A Settings section as a panel: the panels' fill and corners round its
/// header and everything under it.
private struct TVSettingsPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(LineupPanelStyle.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: LineupPanelStyle.radius,
                                                                  style: .continuous))
            .lineupPresentation()
    }
}

private struct AccountSectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    /// Each section's icon, by its name.
    private var symbol: String {
        switch title {
        case "LIVE TV": "antenna.radiowaves.left.and.right"
        case "LIBRARY": "rectangle.stack"
        case "DIAGNOSTICS": "waveform.path.ecg"
        case "APPEARANCE": "paintpalette"
        case "PLAYBACK": "play.rectangle"
        default: "info.circle"
        }
    }

    // The panels' header: icon and heavy caption in light grey, a hairline
    // under them.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LineupPanelHeader(title, systemImage: symbol)
            Rectangle().fill(LineupStyle.line).frame(height: 1)
        }
    }
}

/// One figure on a card: a number over its name.
private struct AccountStat: Identifiable {
    let label: String
    let count: Int?
    var id: String { label }

    init(_ label: String, _ count: Int?) {
        self.label = label
        self.count = count
    }
}

/// Whether a source answers, in words with a mark beside them.
private enum AccountSourceStatus {
    case connected, offline
    case busy(String)

    var title: String {
        switch self {
        case .connected: "Connected"
        case .offline: "Offline"
        case .busy(let word): word
        }
    }
}

private struct AccountStatusMark: View {
    let status: AccountSourceStatus

    var body: some View {
        HStack(spacing: 9) {
            switch status {
            case .connected:
                Circle().fill(LineupPresentationStyle.text).frame(width: 8, height: 8)
            case .offline:
                Circle().strokeBorder(LineupPresentationStyle.secondary, lineWidth: 1.5).frame(width: 9, height: 9)
            case .busy:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 9, height: 9)
            }
            Text(status.title.uppercased())
                .font(.inter(13, .heavy)).tracking(0.6)
        }
        .foregroundStyle(tint)
        .fixedSize()
    }

    private var tint: Color {
        if case .connected = status { return LineupPresentationStyle.text }
        return LineupPresentationStyle.secondary
    }
}

/// A connected source: what it is, whether it answers, what it holds, and
/// what can be done with it, in that order from the top.
private struct AccountSourceCard<Actions: View>: View {
    let symbol: String
    /// A media server's own mark, in place of the symbol.
    var brand: MediaServerBrand? = nil
    let kind: String
    let title: String
    let subtitle: String
    let status: AccountSourceStatus
    let stats: [AccountStat]
    let refreshed: Date?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                AccountGlyph(symbol: symbol, brand: brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.inter(12, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(title)
                        .font(.inter(28, .bold)).foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.inter(17)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                AccountStatusMark(status: status)
            }
            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                    if index > 0 {
                        Rectangle().fill(LineupStyle.line).frame(width: 1, height: 52)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.count.map { $0.formatted() } ?? "—")
                            .font(.interDigits(34, .bold)).foregroundStyle(LineupPresentationStyle.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(stat.label.uppercased())
                            .font(.inter(12, .heavy)).tracking(0.6)
                            .foregroundStyle(LineupPresentationStyle.secondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, index > 0 ? 24 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { actions }
            if let refreshed {
                Text("Updated \(refreshed, style: .relative) ago")
                    .font(.inter(14)).foregroundStyle(LineupPresentationStyle.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
    }
}

/// A source that is not connected, in the shape of the card that would be
/// there if it were, holding the one action that connects it.
private struct AccountEmptySource<Action: View>: View {
    let symbol: String
    /// A media server's own mark, in place of the symbol.
    var brand: MediaServerBrand? = nil
    let kind: String
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                AccountGlyph(symbol: symbol, brand: brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.inter(12, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(title)
                        .font(.inter(28, .bold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(detail)
                        .font(.inter(17)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { action }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LineupStyle.line, style: StrokeStyle(lineWidth: 1, dash: [6, 6])))
    }
}

/// A card's symbol, on a raised disc.
private struct AccountGlyph: View {
    let symbol: String
    /// A media server's own mark, drawn in the same plate instead.
    var brand: MediaServerBrand? = nil

    // The coloured tile the phone's Settings rows carry, at television size.
    var body: some View {
        if let brand {
            MediaServerLogoTile(brand: brand, size: 64)
        } else {
            LineupIconTile(symbol: symbol, size: 64)
        }
    }
}

/// One connected server, in the list that appears when there is more than
/// one. They all feed the Library at once, so a row says how its own server
/// is doing -- whether it answers and what it holds -- rather than offering a
/// choice between them.
private struct AccountServerRow: View {
    @Environment(MediaLibrary.self) private var media
    let profile: MediaServerProfile

    var body: some View {
        let state = media.state(of: profile)
        HStack(spacing: 24) {
            MediaServerLogo(brand: .of(profile)).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.inter(22, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    .lineLimit(1)
                Text(detail(state))
                    .font(.inter(16)).foregroundStyle(LineupPresentationStyle.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 20)
            AccountStatusMark(status: state.isLoading ? .busy("Connecting")
                              : (state.isConnected ? .connected : .offline))
            AccountButton(title: "Remove", symbol: "trash", quiet: true) { media.remove(profile) }
                .fixedSize()
        }
        .padding(.horizontal, 30).padding(.vertical, 20)
    }

    /// Its address, and what it holds once it has said.
    private func detail(_ state: MediaServerState) -> String {
        var parts = [profile.displayHost]
        if let counts = state.counts {
            parts.append("\(counts.movies.formatted()) movies")
            parts.append("\(counts.shows.formatted()) shows")
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// A tile that goes somewhere, sized like its neighbour so a row of them reads
/// as a row rather than as whatever length each title happened to be.
private struct AccountTile<Destination: View>: View {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var isFocused: Bool
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder var destination: Destination

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        NavigationLink { destination } label: {
            HStack(spacing: 20) {
                AccountGlyph(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.inter(24, .bold)).foregroundStyle(LineupPresentationStyle.text)
                    PlaybackEngineMark.text(detail, pointSize: 17).font(.inter(17)).lineLimit(2)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(minHeight: 132)
            .background(LineupPresentationStyle.card, in: shape)
            .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
            .lineupFocusLayer(isFocused, in: shape)
            .scaleEffect(isFocused ? LineupStyle.cardLift : 1)
            .lineupShadow(.lifted, on: isFocused)
            .opacity(enabled ? 1 : 0.45)
        }
        .lineupFlatButton()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// A button on a card. Standard is a raised capsule, prominent adds a white
/// edge for the one thing a card is asking for, and quiet is an outline for
/// what removes something.
/// The channels saved for teams: each team, the channel its games open on,
/// and a press to forget it. The iPhone's Preferred Channels, on the
/// television.
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

private struct AccountButton: View {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    var prominent = false
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccountButtonFace(title: title, symbol: symbol, prominent: prominent, quiet: quiet,
                              focused: isFocused, enabled: enabled)
        }
        .lineupFlatButton()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .frame(maxWidth: .infinity)
    }
}

/// The same button, opening a screen rather than running an action.
private struct AccountLinkButton<Destination: View>: View {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink { destination } label: {
            AccountButtonFace(title: title, symbol: symbol, prominent: false, quiet: false,
                              focused: isFocused, enabled: enabled)
        }
        .lineupFlatButton()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .frame(maxWidth: .infinity)
    }
}

/// What every account button looks like. The symbol and the words are laid
/// side by side on their centres: a label lines text up with the symbol's
/// baseline, which lifted some words a point or two above their neighbours'.
private struct AccountButtonFace: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let quiet: Bool
    let focused: Bool
    let enabled: Bool

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 12) {
            LineupIconTile(symbol: symbol, size: 34)
            Text(title).font(.inter(18, .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(quiet && !focused ? LineupPresentationStyle.secondary : LineupPresentationStyle.text)
        .padding(.leading, 11).padding(.trailing, 24).frame(height: 56)
        .frame(maxWidth: .infinity)
        // On a card, a step lighter than the card, as a pressed row is.
        .background(quiet ? Color.clear : LineupPresentationStyle.row, in: shape)
        .overlay(shape.strokeBorder(prominent ? LineupPresentationStyle.text.opacity(0.7) : LineupStyle.line,
                                    lineWidth: prominent ? 1.5 : 1))
        .lineupFocusLayer(focused, in: shape)
        .scaleEffect(focused ? LineupStyle.controlLift : 1)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A tab and the engine it plays with, which choosing the row changes.
private struct AccountEngineRow: View {
    let place: TVPlaybackPlace
    let engine: TVPlaybackEngine
    let action: () -> Void

    var body: some View {
        TVSelectable(scale: 1.015, fillRadius: 18, action: action) {
            HStack(spacing: 20) {
                LineupIconTile(symbol: place.symbol, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.title).font(.inter(24, .semibold))
                    Text(place.detail).font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                PlaybackEngineText(engine.title, size: 21)
                    .font(.inter(21, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                Image(systemName: "chevron.right").font(.inter(20, .semibold))
            }
            .padding(24)
            .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityLabel("\(place.title) playback engine, \(engine.title)")
    }
}

/// One of the Library's own actions: its tile, its name and a line on what it
/// does, in the well the other Settings rows sit in.
private struct AccountActionRow: View {
    @Environment(\.isEnabled) private var enabled
    let symbol: String
    let title: String
    let detail: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        TVSelectable(scale: 1.015, fillRadius: 18, action: action) {
            HStack(spacing: 20) {
                LineupIconTile(symbol: symbol, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.inter(24, .semibold))
                        .foregroundStyle(destructive ? LineupIconTile.red : LineupPresentationStyle.text)
                    Text(detail).font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(.inter(20, .semibold))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .opacity(enabled ? 1 : 0.42)
    }
}

/// A card that leads somewhere: what it sets, and a button that opens it. The
/// same shape as a source card, so a row of the two lines up.
private struct AccountLinkCard<Destination: View>: View {
    let symbol: String
    let kind: String
    let title: String
    let detail: String
    let action: String
    let actionSymbol: String
    @ViewBuilder var destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                AccountGlyph(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.inter(12, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(title)
                        .font(.inter(28, .bold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(detail)
                        .font(.inter(17)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            AccountLinkButton(title: action, symbol: actionSymbol) { destination }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
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

private struct AccountRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(label.uppercased())
                .font(.inter(13, .heavy)).tracking(0.6)
                .foregroundStyle(LineupPresentationStyle.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.inter(19, .medium)).foregroundStyle(LineupPresentationStyle.text)
                .multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
