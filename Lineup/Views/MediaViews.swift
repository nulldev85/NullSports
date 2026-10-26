import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// A title somebody chose to play.
struct MediaPlayRequest: Identifiable {
    let item: MediaItem
    let id = UUID()
}

/// Opens a title's streams from the Library tab itself, rather than from the
/// poster that was chosen.
///
/// The stream list, and the player it opens, live as long as whatever
/// presented them, and a poster in a row is a poor owner. The rows are lazy
/// and let go of a poster that moves out of reach, and Continue Watching
/// reorders itself as a title plays and drops an episode the moment it counts
/// as watched -- three or four minutes before its end. Each of those took the
/// player with it, mid-episode. The tab outlives all of that.
struct MediaPlayAction {
    let play: (MediaItem) -> Void
    func callAsFunction(_ item: MediaItem) { play(item) }
}

private struct MediaPlayActionKey: EnvironmentKey {
    static let defaultValue: MediaPlayAction? = nil
}

extension EnvironmentValues {
    var playMedia: MediaPlayAction? {
        get { self[MediaPlayActionKey.self] }
        set { self[MediaPlayActionKey.self] = newValue }
    }
}

struct MediaServersView: View {
    @Environment(MediaLibrary.self) private var media
    @State private var addingServer = false
    @State private var showingSeerr = false
    @State private var choosingShelf = false
    @State private var reorderingShelves = false
    @State private var clearingHistory = false
    @State private var searchingLibrary = false
    @State private var playing: MediaPlayRequest?
    /// The Library's options, dropped from the bar's ellipsis.
    @State private var optionsOpen = false
    #if !os(tvOS)
    @State private var collectionsOpen = false
    @State private var newCollectionName = ""
    #endif
    /// Bumped to take the phone's Library back to its front page: an episode
    /// that ended with nothing after it leads there.
    @State private var frontPage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        stack
            .environment(\.playMedia, MediaPlayAction { playing = MediaPlayRequest(item: $0) })
            #if os(tvOS)
            .lineupFullScreenCover(item: $playing) { request in MediaSourcePicker(item: request.item) }
            #else
            .lineupSheet(item: $playing) { request in MediaSourcePicker(item: request.item) }
            .lineupSheet(item: Bindable(media).collectionSelectionItem) { item in MobileAddToCollectionView(item: item).environment(media) }
            .lineupTextPrompt("New Collection", symbol: "folder.badge.plus", isPresented: Bindable(media).creatingCollection,
                text: $newCollectionName, prompt: "Collection name", saveTitle: "Create",
                canSave: !newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && newCollectionName.count <= 80,
                onSave: {
                    media.createCollection(named: newCollectionName, adding: media.collectionCreationItem)
                    newCollectionName = ""
                    media.collectionCreationItem = nil
                }, onCancel: { newCollectionName = ""; media.collectionCreationItem = nil })
            .mobileTabHome(.library) {
                optionsOpen = false
                searchingLibrary = false
                frontPage &+= 1
            }
            #endif
    }

    private var stack: some View {
        NavigationStack {
            Group {
            #if os(tvOS)
            TVMediaServersHome(addingServer: $addingServer, searchingLibrary: $searchingLibrary)
            #else
            Group {
                // The built-in rows come from public charts and need no server:
                // they show first, and a server's own shelves join them as it
                // loads. This waits only while there is nothing at all to show.
                if !media.hasAnySource && media.builtInShelves.isEmpty {
                    LineupUnavailableView(title: "Add a Media Server", symbol: "play.square.stack",
                                          description: Text("Connect a Jellyfin, Emby, Plex or Silo server to watch your own library here.")) {
                        VStack(spacing: 18) {
                            MediaServerLogoRow(size: 34)
                            Button("Add Media Server") { addingServer = true }
                                .lineupProminentButton()
                        }
                    }
                } else if media.hasAnySource && media.roots.isEmpty && media.isLoading && media.builtInShelves.isEmpty {
                    ProgressView("Loading libraries…")
                } else if media.hasAnySource && media.shelves.isEmpty && media.loadFailed {
                    // Not "Choose Your Shelves". An attempt that failed and a
                    // server with nothing selected look identical from here,
                    // and telling a viewer to pick shelves that could not be
                    // fetched sends them looking for a setting to fix.
                    LineupUnavailableView(
                        title: media.profiles.count > 1 ? "Can't Reach Your Servers" : "Can't Reach Your Server",
                        symbol: "exclamationmark.triangle",
                        description: Text(media.profiles.count > 1
                             ? "Lineup couldn't load your libraries. Check that your servers are running and reachable from this network."
                             : "Lineup couldn't load your libraries. Check that the server is running and reachable from this network.")) {
                        Button("Try Again") { Task { await media.reload() } }
                            .lineupProminentButton()
                    }
                } else {
                    MediaCatalogsScreen(catalogs: media.mobileShelfCatalogs, searchPresented: $searchingLibrary,
                                        onAddServer: media.hasAnySource ? nil : { addingServer = true })
                }
            }
            .background(LineupStyle.background.ignoresSafeArea())
            .overlay {
                MobileDropdownLayer(isPresented: optionsOpen, title: "Library", symbol: "rectangle.stack",
                                    sections: optionsSections) { setOptions(false) }
            }
            .modifier(ClearLibraryHeader())
            .navigationDestination(isPresented: $collectionsOpen) { MobileLibraryCollectionsView() }
            .toolbar {
                LineupToolbarItem(placement: .primaryAction) {
                    MobileDropdownButton(isOpen: optionsOpen, label: "Library options") {
                        setOptions(!optionsOpen)
                    }
                }
            }
            #endif
            }
            .lineupSheet(isPresented: $addingServer) {
                MediaServerSetupView()
                    .environment(media)
                    .preferredColorScheme(.dark)
            }
            .lineupSheet(isPresented: $showingSeerr) {
                NavigationStack { SeerrSettingsView().environment(media) }
            }
            .lineupSheet(isPresented: $choosingShelf) {
                MediaShelfPicker().environment(media)
            }
            .lineupSheet(isPresented: $reorderingShelves) {
                LibraryShelfOrderSheet().environment(media)
                    .preferredColorScheme(.dark)
            }
            // Not `.task`. A task belongs to the view, and this work does not:
            // leaving the tab mid-load used to cancel it and leave the tab
            // stuck on its spinner. The store owns the load and decides whether
            // one is needed; appearing only asks.
            .onAppear {
                media.refreshCatalogRowsIfNeeded()
                media.loadShelvesIfNeeded()
                // The IPTV provider's list is read ahead, for its shelves and
                // so the first title played does not wait on all of it.
                Task { await media.loadProviderShelves() }
                media.providerVOD.prefetch()
            }
            .onChange(of: media.profiles.map(\.id)) { _, _ in media.loadShelvesIfNeeded() }
            #if os(tvOS)
            .tvChoices("Media Server", symbol: "exclamationmark.triangle",
                       isPresented: Binding(get: { media.errorMessage != nil },
                                            set: { if !$0 { media.errorMessage = nil } }),
                       message: media.errorMessage ?? "Unknown error", cancelTitle: "OK") { [] }
            .tvChoices("Clear local tracking?", symbol: "trash", isPresented: $clearingHistory,
                       message: "This removes Continue Watching and local watched status from this Apple TV.") {
                [TVChoice("Clear Local Tracking", isDestructive: true) { media.clearLocalPlayback() }]
            }
            #else
            .lineupChoices("Media Server", symbol: "exclamationmark.triangle",
                           isPresented: Binding(get: { media.errorMessage != nil },
                                                set: { if !$0 { media.errorMessage = nil } }),
                           message: media.errorMessage ?? "Unknown error", cancelTitle: "OK") { [] }
            .lineupChoices("Clear local tracking?", symbol: "trash", isPresented: $clearingHistory,
                           message: "This removes Continue Watching and local watched status from this device.") {
                [MobileMenuItem("Clear Local Tracking", isDestructive: true) { media.clearLocalPlayback() }]
            }
            #endif
        }
        #if !os(tvOS)
        // A new stack is the front page: whatever pages were pushed go with
        // the old one.
        .id(frontPage)
        .onReceive(NotificationCenter.default.publisher(for: .lineupReturnToLibraryFront)) { _ in
            frontPage += 1
        }
        #endif
    }

    #if !os(tvOS)
    private func setOptions(_ open: Bool) {
        guard optionsOpen != open else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
            optionsOpen = open
        }
    }

    /// What the Library's dropdown offers: its shelves -- the ones that can
    /// go a list of their own inside it -- then its servers.
    private var optionsSections: [MobileMenuSection] {
        let removable = media.removableShelves.map { shelf in
            MobileMenuItem(media.shelfName(shelf), id: "remove-\(shelf.id)", isDestructive: true) {
                media.removeShelf(shelf)
            }
        }
        var servers = [
            MobileMenuItem("Seerr · Discover & Requests", imageName: "SeerrLogo") { showingSeerr = true },
            MobileMenuItem("Refresh", symbol: "arrow.clockwise",
                           isEnabled: !media.isLoading && media.hasAnySource) {
                Task { await media.reload() }
            },
            MobileMenuItem("Add Server", symbol: "externaldrive.badge.plus") { addingServer = true }
        ]
        if !media.continueWatching.isEmpty || !media.watchHistory.isEmpty {
            servers.append(MobileMenuItem("Clear Local Tracking", symbol: "trash", isDestructive: true) {
                clearingHistory = true
            })
        }
        return [
            MobileMenuSection(id: "shelves", items: [
                MobileMenuItem("Search", symbol: "magnifyingglass", isEnabled: !media.shelves.isEmpty) {
                    searchingLibrary = true
                },
                MobileMenuItem("Collections", symbol: "folder.fill") { collectionsOpen = true },
                MobileMenuItem("Add Shelf", symbol: "plus.rectangle.on.rectangle", isEnabled: media.hasAnySource) {
                    choosingShelf = true
                },
                MobileMenuItem("Remove Shelf", symbol: "minus.rectangle", isEnabled: !removable.isEmpty,
                               children: [MobileMenuSection(id: "removable", items: removable)]),
                MobileMenuItem("Edit Shelves", symbol: "arrow.up.arrow.down",
                               isEnabled: media.libraryRows.count >= 2) {
                    reorderingShelves = true
                }
            ]),
            MobileMenuSection(id: "servers", items: servers)
        ]
    }
    #endif
}

/// One figure on an account card. A count the app has not learned yet passes
/// nil and shows an em dash rather than a zero it cannot stand behind.
struct LineupCardStat: Identifiable {
    let label: String
    let count: Int?
    var id: String { label }

    init(_ label: String, _ count: Int?) {
        self.label = label
        self.count = count
    }
}

/// The card the Account tab is built from.
///
/// There are two of these -- the provider and the media server -- and they are
/// the tab's whole look, so they are one view rather than two that resemble
/// each other. A glass circle on the left and a glass capsule on the right
/// bracket the header; a filled disc against bare text did not. The figures
/// below are equal columns divided by hairlines, because left-aligned thirds
/// left the last one floating well short of the right edge and the row reading
/// lopsided.
struct LineupAccountCard<Actions: View>: View {
    let symbol: String
    /// A media server's own mark, in place of the symbol.
    var brand: MediaServerBrand? = nil
    let title: String
    let subtitle: String
    let connected: Bool
    let status: String
    let statusTint: Color
    let stats: [LineupCardStat]
    let refreshed: Date?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                    if index > 0 {
                        Rectangle().fill(LineupStyle.line).frame(width: 1, height: rule)
                    }
                    statistic(stat)
                }
            }
            HStack(spacing: 10) { actions }
            if let refreshed {
                Text("Updated \(refreshed, style: .relative)")
                    .font(.inter(.caption2))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(cardPadding)
        .frame(maxWidth: maxCardWidth, alignment: .leading)
        #if os(tvOS)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: cardRadius, style: .continuous),
                           fallback: LineupStyle.surface, border: LineupStyle.line)
        #else
        // A card in the panels' grey: in a Settings row it is the row.
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        #endif
    }

    // A television is not a large phone. The type scales itself -- a text style
    // resolves bigger there -- but padding, a glyph circle and a corner do not,
    // and a card built to phone measurements reads as a postage stamp from
    // across a room.
    #if os(tvOS)
    private var cardPadding: CGFloat { 30 }
    private var maxCardWidth: CGFloat { 900 }
    private var cardRadius: CGFloat { 26 }
    private var glyph: CGFloat { 72 }
    private var glyphSize: CGFloat { 32 }
    private var rule: CGFloat { 44 }
    #else
    private var cardPadding: CGFloat { 16 }
    private var maxCardWidth: CGFloat { 720 }
    private var cardRadius: CGFloat { 18 }
    private var glyph: CGFloat { 42 }
    private var glyphSize: CGFloat { 20 }
    private var rule: CGFloat { 26 }
    #endif

    private var header: some View {
        HStack(spacing: 12) {
            #if os(tvOS)
            Group {
                if let brand {
                    MediaServerLogo(brand: brand).frame(width: glyph * 0.52, height: glyph * 0.52)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: glyphSize, weight: .semibold, design: .rounded))
                }
            }
                .frame(width: glyph, height: glyph)
                .lineupLiquidGlass(Circle(), fallback: LineupStyle.raised,
                                   border: LineupStyle.line)
            #else
            // The same coloured tile as the Settings rows around it; a
            // server's own mark sits on a dark one, the way an app icon does.
            if let brand {
                MediaServerLogoTile(brand: brand, size: glyph)
            } else {
                LineupIconTile(symbol: symbol, size: glyph)
            }
            #endif
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.inter(.headline, .bold)).lineLimit(1)
                    LineupStatusDot(connected: connected)
                }
                Text(subtitle)
                    .font(.inter(.caption)).lineLimit(1)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
            }
            Spacer(minLength: 8)
            // A floor under the width so the header does not shuffle as the
            // word changes between connecting, connected and offline.
            #if os(tvOS)
            Text(status)
                .font(.inter(.caption2, .semibold))
                .foregroundStyle(statusTint)
                .lineLimit(1)
                .frame(minWidth: 74)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .lineupLiquidGlass(Capsule(), fallback: LineupStyle.raised,
                                   border: LineupStyle.line)
            #else
            // Flat and grey like the card under it: white words while
            // connected, grey while not.
            Text(status)
                .font(.inter(.caption2, .semibold))
                .foregroundStyle(connected ? LineupStyle.text : LineupStyle.secondary)
                .lineLimit(1)
                .frame(minWidth: 74)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(LineupStyle.focused, in: Capsule())
                .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 0.5))
            #endif
        }
    }

    private func statistic(_ stat: LineupCardStat) -> some View {
        VStack(spacing: 3) {
            Text(stat.count.map { $0.formatted() } ?? "—")
                .font(.interDigits(.headline, .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(stat.label).font(.inter(.caption2))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
    }
}

/// The provider, told the same way the media server is told.
///
/// The tab used to give the media server a card and the provider a plain row,
/// which was backwards: the provider is the thing the app is mostly about. Both
/// are cards now, and both are the same card -- one view, two sets of figures
/// -- so neither can drift into looking like the other's poor relation.
///
/// Shared, because the phone and the television show the same two cards and
/// there is no version of this that should differ between them.
struct ProviderAccountCard: View {
    @Environment(SportsLibrary.self) private var library
    let profile: XtreamProfile
    let openGuide: () -> Void

    /// Channels in hand is what "ready" means here. A provider mid-sync still
    /// has whatever it restored from disk, and that is worth watching.
    private var ready: Bool { !library.streams.isEmpty }

    private var status: String {
        if library.channelsAreSyncing { return "Updating…" }
        return ready ? "Connected" : "Offline"
    }

    var body: some View {
        LineupAccountCard(
            symbol: "antenna.radiowaves.left.and.right",
            title: profile.name,
            subtitle: "\(profile.username) · \(URL(string: profile.serverURL)?.host ?? profile.serverURL)",
            connected: ready,
            status: status,
            statusTint: ready ? Color.green : LineupStyle.lightPurple.opacity(0.5),
            stats: [
                LineupCardStat("Channels", library.streams.count),
                LineupCardStat("Favorites", library.favoriteStreamOrder.count),
                LineupCardStat("Teams", library.teamPreferences.listed().count)
            ],
            refreshed: library.lastRefreshedAt
        ) {
            LineupCardAction(title: "Refresh", symbol: "arrow.clockwise") {
                Task { await library.reload() }
            }
            .disabled(library.channelsAreSyncing || library.isSwitchingProfile)
            LineupCardAction(title: "TV Guide", symbol: "calendar", action: openGuide)
        }
    }
}

/// A compact account summary of the connected servers, which the Library uses
/// together. Counts come from the servers' total-record queries, never from
/// the first page of shelf cards.
struct MediaServerAccountCard: View {
    @Environment(MediaLibrary.self) private var media
    let browse: () -> Void

    var body: some View {
        LineupAccountCard(
            symbol: "play.square.stack.fill",
            brand: MediaServerBrand.shared(by: media.profiles),
            title: title,
            subtitle: subtitle,
            connected: media.isConnected,
            status: status,
            statusTint: media.isConnected ? Color.green : LineupStyle.lightPurple.opacity(0.5),
            stats: [
                LineupCardStat("Movies", media.libraryCounts?.movies),
                LineupCardStat("Shows", media.libraryCounts?.shows),
                LineupCardStat("Episodes", media.libraryCounts?.episodes)
            ],
            refreshed: media.lastRefreshedAt
        ) {
            LineupCardAction(title: "Reload", symbol: "arrow.clockwise") {
                Task { await media.reload() }
            }
            .disabled(media.isLoading)
            LineupCardAction(title: "Browse", symbol: "square.grid.2x2", action: browse)
        }
    }

    private var title: String {
        guard media.profiles.count > 1 else { return media.profiles.first?.name ?? "Media Server" }
        return "\(media.profiles.count) media servers"
    }

    private var subtitle: String {
        guard media.profiles.count > 1 else {
            guard let profile = media.profiles.first else { return "" }
            return "\(profile.username) · \(profile.displayHost)"
        }
        return media.profiles.map(\.name).joined(separator: " · ")
    }

    private var status: String {
        if media.isLoading { return "Connecting…" }
        let answering = media.profiles.filter { media.state(of: $0).isConnected }.count
        guard media.profiles.count > 1, answering > 0 else { return answering > 0 ? "Connected" : "Offline" }
        return answering == media.profiles.count ? "All connected" : "\(answering) of \(media.profiles.count) connected"
    }
}

struct LineupCardAction: View {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            #if os(tvOS)
            LineupTileLabel(title: title, symbol: symbol, tileSize: 34)
                .font(.inter(.subheadline, .semibold))
                .frame(maxWidth: .infinity, minHeight: 66)
                .background(LineupPanelStyle.well, in: Capsule())
                .lineupFocusLayer(focused, in: Capsule())
                .scaleEffect(focused ? LineupStyle.controlLift : 1)
            #else
            // The reference app's way with a labelled control: the icon on
            // its coloured tile, the words beside it, on a step lighter than
            // the card. Dimmed while unavailable.
            LineupTileLabel(title: title, symbol: symbol, tileSize: 24)
                .font(.inter(.subheadline, .bold))
                .foregroundStyle(LineupStyle.text)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(LineupPanelStyle.well, in: Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.5)
            #endif
        }
        .lineupFlatButton()
    }
}

struct LineupStatusDot: View {
    let connected: Bool

    #if os(tvOS)
    private static let size: CGFloat = 14
    #else
    private static let size: CGFloat = 9
    #endif

    private var fill: Color {
        #if os(tvOS)
        Color(red: 0.29, green: 0.84, blue: 0.45)
        #else
        LineupStyle.text
        #endif
    }

    var body: some View {
        // A plain dot when connected and a ring when not. It was a glossy
        // bead with a glow and a pulsing halo; nothing in the app glows now
        // but the pale rim that keeps a dark team badge readable.
        Circle().fill(connected ? fill : Color.clear)
            .overlay(Circle().strokeBorder(LineupStyle.secondary, lineWidth: connected ? 0 : 1.5))
            .frame(width: Self.size, height: Self.size)
            .accessibilityLabel(connected ? "Connected" : "Not connected")
    }
}

#if os(tvOS)
/// The Library tab on Apple TV: its shelves, or what stands in for them. What
/// the Library's menu used to offer -- shelves, collections, refreshing --
/// is in Settings › Library.
private struct TVMediaServersHome: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.tvTabBar) private var tabBar
    @Binding var addingServer: Bool
    @Binding var searchingLibrary: Bool

    var body: some View {
        Group {
            if !media.hasAnySource {
                TVMediaEmptyState(addServer: { addingServer = true })
            } else if media.roots.isEmpty && media.isLoading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Loading your libraries…").font(.inter(.headline))
                }
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if media.roots.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.exclamationmark").font(.system(size: 42, weight: .light, design: .rounded))
                    Text("No libraries found").font(.inter(.title2, .semibold))
                    Text(media.profiles.count > 1
                         ? "Reload your servers in Settings › Library, or confirm these accounts can access a library."
                         : "Reload the server in Settings › Library, or confirm this account can access a library.")
                        .font(.inter(.callout)).opacity(0.68)
                }
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaCatalogsScreen(catalogs: media.shelves, searchPresented: $searchingLibrary)
            }
        }
        // Back on the Library's own screen: no title's page is over it, so
        // the tab bar is up whatever the pages that closed did or did not say.
        .onAppear { tabBar?.reset() }
        // Collections from a card's hold menu, anywhere in the Library. The
        // Collections screen, opened from Settings, has its own while it is up.
        .lineupFullScreenCover(item: Binding(get: { media.collectionsScreenShown ? nil : media.collectionSelectionItem },
                                       set: { media.collectionSelectionItem = $0 })) { item in
            TVCollectionPicker(item: item).environment(media)
        }
        .background(
            ZStack {
                LineupStyle.background
                RadialGradient(colors: [LineupStyle.lightPurple.opacity(0.055), .clear],
                    center: .topTrailing, startRadius: 30, endRadius: 760)
            }.ignoresSafeArea()
        )
    }
}

private struct TVMediaEmptyState: View {
    let addServer: () -> Void
    var body: some View {
        HStack(spacing: 34) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(LineupStyle.surface)
                MediaServerLogoRow(size: 52)
            }
            .frame(width: 210, height: 150)
            VStack(alignment: .leading, spacing: 12) {
                Text("Bring your media to the big screen.")
                    .font(.inter(32, .semibold))
                Text("Connect your Jellyfin, Emby or Plex server and watch your own library on the big screen.")
                    .font(.inter(18)).opacity(0.68).frame(maxWidth: 590, alignment: .leading)
                HStack(spacing: 16) {
                    Button("Connect a Server", systemImage: "plus", action: addServer)
                }
                .lineupButtonStyle().padding(.top, 6)
            }
            .foregroundStyle(LineupStyle.lightPurple)
        }
        .padding(42)
        .background(LineupStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(LineupStyle.line, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 90).padding(.bottom, 80)
    }
}

#endif

enum LibraryHeroRotation {
    static let interval: Duration = .seconds(4)

    static func animation(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.2 : 0.75)
    }
}

/// Restart the dwell when the selection, its contents, or interaction changes.
/// Item identities include the server, since two servers may use the same ID.
struct LibraryHeroRotationKey: Equatable {
    let items: [String]
    let index: Int
    let enabled: Bool
    var pixels: Int = 0
}

struct MediaCatalogsScreen: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let catalogs: [MediaCatalog]
    @Binding var searchPresented: Bool
    /// Given while no media server is connected: the rows are only to look at
    /// until one is, and this is where adding one starts.
    var onAddServer: (() -> Void)? = nil
    @State private var query = ""
    // On tvOS the sheet edits a draft. Search only the submitted value: remote
    // typing otherwise launches and cancels a network search for every letter.
    @State private var submittedQuery = ""
    @State private var searchRequestID = UUID()
    @State private var results: [MediaLibrary.SearchGroup] = []
    @State private var searching = false
    @State private var searchError: String?
    @FocusState private var searchFocused: Bool
    // tvOS pushes by hand because its cards are not NavigationLinks any more.
    @State private var pushed: MediaItem?
    @State private var heroPlayableItem: MediaItem?
    @State private var isVisible = false
    #if !os(tvOS)
    @State private var phoneScrollActivity = MobileLibraryScrollActivity()
    #endif
    #if os(tvOS)
    @StateObject private var tvPreview = TVMediaPreviewState()
    @Environment(\.tvTabBar) private var tabBar
    @Environment(\.playMedia) private var playMedia
    /// Where the remote is: the hero's Play, or a card in the shelf row. The
    /// focus engine moves it; the screen adds only what the engine cannot --
    /// see `moveTV(_:from:)`.
    @FocusState private var tvFocus: TVLibraryFocus?
    /// The one shelf in the row at the foot of the screen.
    @State private var shelfIndex = 0
    /// The card each shelf was left on, so coming back to it lands there.
    @State private var shelfColumns: [String: Int] = [:]
    /// Which way the last change of shelf went, for its transition.
    @State private var shelfStepDown = true
    @State private var heroIndex = 0
    @State private var focusedCard: MediaItem?
    @State private var lastFocusedCard: MediaItem?
    #endif

    private var continueWatching: [LocalMediaPlayback] { Array(media.continueWatching.prefix(20)) }
    /// The rows the Library comes with -- what is trending, the streaming
    /// services -- then every shelf.
    private var shownShelves: [MediaCatalog] { media.builtInShelves + catalogs }
    private var favoriteTitles: [MediaItem] { media.favoriteMedia.filter { $0.type != "Episode" } }
    private var favoriteEpisodes: [MediaItem] { media.favoriteMedia.filter { $0.type == "Episode" } }
    #if os(tvOS)
    /// The hero's first title, which is where the remote starts.
    private var defaultPreviewItem: MediaItem? {
        heroItems.first
            ?? continueWatching.first?.item
            ?? catalogs.first(where: { !$0.items.isEmpty })?.items.first
            ?? favoriteTitles.first
            ?? favoriteEpisodes.first
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if !submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("SEARCH RESULTS").font(.inter(10, .bold)).tracking(1.3).opacity(0.48)
                            Text(submittedQuery).font(.inter(sectionTitleFontSize, .semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        #if os(tvOS)
                        TVSelectable(scale: LineupStyle.controlLift, action: clearSearch) {
                            MediaChromeLabel { Label("Back to Library", systemImage: "xmark") }
                        }
                        #else
                        Button(action: clearSearch) {
                            MediaChromeLabel { Label("Library", systemImage: "xmark") }
                        }.lineupFlatButton()
                        #endif
                    }
                    .padding(.horizontal, horizontalPadding).padding(.vertical, 16)
                    .lineupFocusRegion()
                    if searching && results.isEmpty {
                        ProgressView("Searching your library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let searchError {
                        LineupUnavailableView("Search Unavailable", systemImage: "exclamationmark.triangle", description: Text(searchError))
                    } else if results.isEmpty {
                        LineupUnavailableView("No Results", systemImage: "magnifyingglass",
                            description: Text("Nothing in your connected libraries matched that."))
                    } else {
                        // One section per server once there is more than
                        // one, each headed by its server's name.
                        MediaGridScreen(title: "Search Results", sections: results.map { group in
                            MediaGridSection(id: group.serverID.uuidString,
                                             title: results.count > 1 ? group.serverName : nil,
                                             brand: results.count > 1 ? media.serverBrand(of: group.serverID) : nil,
                                             items: group.items)
                        })
                    }
                }
            } else {
                if shownShelves.isEmpty && continueWatching.isEmpty
                    && favoriteTitles.isEmpty && favoriteEpisodes.isEmpty {
                    #if os(tvOS)
                    LineupUnavailableView("Choose Your Shelves", systemImage: "rectangle.stack.badge.plus",
                        description: Text("Trending Movies, Trending Shows and Streaming Services appear here in a moment. Add any other shelf you want from Settings › Library › Add Shelf."))
                    #else
                    LineupUnavailableView("Choose Your Shelves", systemImage: "rectangle.stack.badge.plus",
                        description: Text("Trending Movies, Trending Shows and Streaming Services appear here in a moment. Add any other shelf you want from Add Shelf."))
                    #endif
                } else {
                    #if os(tvOS)
                    tvBrowser
                    #else
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: catalogSpacing) {
                            if let heroCatalog = media.heroCatalog {
                                // The first panel starts a gap below the
                                // hero, as each starts a gap below the last.
                                MediaLibraryHero(catalog: heroCatalog, onOpen: openHeroItem,
                                                 scrollActivity: phoneScrollActivity)
                            }
                            if let onAddServer {
                                MobileAddServerPrompt(action: onAddServer)
                                    .padding(.horizontal, horizontalPadding)
                                    .padding(.top, media.heroCatalog == nil ? 110 : 0)
                            }
                            libraryShelves
                        }
                        .padding(.bottom, 44)
                    }
                    .scrollBounceBehavior(.always, axes: .vertical)
                    .onScrollPhaseChange { _, phase in phoneScrollActivity.isActive = phase != .idle }
                    .onDisappear { phoneScrollActivity.isActive = false }
                    .ignoresSafeArea(edges: .top)
                    #endif
                }
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        // An episode that ended with nothing after it comes back here.
        .onReceive(NotificationCenter.default.publisher(for: .lineupReturnToLibraryFront)) { _ in
            pushed = nil
        }
        .lineupSheet(isPresented: $searchPresented) { searchSheet }
        #if os(tvOS)
        .lineupFullScreenCover(item: $heroPlayableItem) { item in MediaSourcePicker(item: item) }
        #else
        .lineupSheet(item: $heroPlayableItem) { item in MediaSourcePicker(item: item) }
        #endif
        .task(id: searchRequestID) {
            let value = submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { results = []; searching = false; searchError = nil; return }
            searching = true
            searchError = nil
            results = []
            #if !os(tvOS)
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            #endif
            guard !Task.isCancelled else { return }
            do {
                let found = try await media.search(value)
                guard !Task.isCancelled else { return }
                results = found; searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []; searchError = error.localizedDescription
            }
            searching = false
        }
        #if os(tvOS)
        .task(id: LibraryHeroRotationKey(items: heroItems.map(\.libraryKey), index: heroIndex,
                                        enabled: canRotateLibraryPreview)) {
            guard canRotateLibraryPreview else { return }
            await rotateLibraryPreview()
        }
        .onAppear {
            tvPreview.setInitial(defaultPreviewItem)
        }
        .onChange(of: media.profiles.map(\.id)) { _, _ in tvPreview.reset(to: defaultPreviewItem) }
        #endif
    }

    /// One of the phone's rows: the device's own, or a shelf.
    private enum PhoneRow: Identifiable {
        #if !os(tvOS)
        case collections
        #endif
        case local(id: String, title: String, items: [MediaItem], opensPages: Bool)
        case catalog(MediaCatalog)

        var id: String {
            switch self {
            #if !os(tvOS)
            case .collections: LibraryShelfOrder.collections
            #endif
            case .local(let id, _, _, _): id
            case .catalog(let catalog): catalog.id
            }
        }
    }

    /// Every row, in the order the viewer arranged them.
    private var phoneRows: [PhoneRow] {
        var rows: [PhoneRow] = []
        #if !os(tvOS)
        rows.append(.collections)
        #endif
        if !continueWatching.isEmpty {
            rows.append(.local(id: LibraryShelfOrder.continueWatching, title: "Continue Watching",
                               items: continueWatching.map(\.item), opensPages: true))
        }
        rows += media.builtInShelves.map(PhoneRow.catalog)
        if !favoriteTitles.isEmpty {
            rows.append(.local(id: LibraryShelfOrder.favorites, title: "Favorites",
                               items: favoriteTitles, opensPages: false))
        }
        if !favoriteEpisodes.isEmpty {
            rows.append(.local(id: LibraryShelfOrder.favoriteEpisodes, title: "Favorite Episodes",
                               items: favoriteEpisodes, opensPages: false))
        }
        rows += catalogs.map(PhoneRow.catalog)
        return media.arrangedShelves(rows, id: \.id).map { row in
            guard case .local(let id, let title, let items, let opensPages) = row else { return row }
            return .local(id: id, title: media.shelfTitle(id: id, default: title), items: items, opensPages: opensPages)
        }
    }

    @ViewBuilder
    private var libraryShelves: some View {
        ForEach(phoneRows) { row in
            switch row {
            #if !os(tvOS)
            case .collections:
                MobileLibraryCollectionsRow()
            #endif
            case .local(let id, let title, let items, let opensPages):
                localShelf(id: id, title: title, items: items, opensPages: opensPages)
            case .catalog(let catalog):
                catalogShelf(catalog)
            }
        }
    }

    /// A shelf: a server's, MDBList's, the provider's, or the Streaming
    /// Services row.
    private func catalogShelf(_ catalog: MediaCatalog) -> some View {
        VStack(alignment: .leading, spacing: shelfStackSpacing) {
            #if os(tvOS)
            HStack(alignment: .firstTextBaseline) {
                TVShelfTitle(title: media.shelfTitle(catalog), symbol: Self.shelfSymbol(catalog.id))
                // Which server a shelf comes from, once there is more than
                // one: two of them can each have a "Trending Movies".
                if let server = media.serverName(for: catalog) {
                    HStack(spacing: 5) {
                        if let brand = media.serverBrand(for: catalog) {
                            MediaServerLogo(brand: brand).frame(width: 11, height: 11)
                        }
                        Text(server.uppercased())
                            .font(.inter(10, .bold)).tracking(1.2)
                            .foregroundStyle(LineupStyle.lightPurple.opacity(0.42))
                            .lineLimit(1)
                    }
                }
                Spacer()
                #if os(tvOS)
                TVSelectable(scale: LineupStyle.controlLift, action: { pushed = catalog.root }) {
                    MediaChromeLabel {
                        Label("See All", systemImage: "chevron.right")
                            .font(.inter(14, .semibold))
                    }
                }
                // Holding Select on a shelf's See All offers to take the
                // shelf away, without going up to the options for it.
                .tvHoldMenu(media.shelfTitle(catalog), symbol: "rectangle.stack") {
                    [TVChoice("Remove Shelf", symbol: "minus.rectangle", isDestructive: true) {
                        media.removeShelf(catalog)
                    }]
                }
                #endif
            }
            .padding(.horizontal, horizontalPadding)
            #else
            PhoneShelfHeader(title: media.shelfTitle(catalog), symbol: Self.shelfSymbol(catalog.id)) {
                // Which server a shelf comes from, once there is more than
                // one: two of them can each have a "Trending Movies".
                if let server = media.serverName(for: catalog) {
                    HStack(spacing: 5) {
                        if let brand = media.serverBrand(for: catalog) {
                            MediaServerLogo(brand: brand).frame(width: 11, height: 11)
                        }
                        Text(server.uppercased())
                            .font(.inter(10, .bold)).tracking(1.2)
                            .foregroundStyle(LineupPanelStyle.quiet)
                            .lineLimit(1)
                    }
                    .layoutPriority(-1)
                }
                NavigationLink(value: catalog.root) {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .heavy, design: .rounded))
                    }
                    .font(.inter(14, .bold))
                    .foregroundStyle(LineupStyle.highlight)
                    .fixedSize()
                }.lineupFlatButton()
            }
            #endif
            // See All is deliberately not a focus section. From the body
            // of a shelf, vertical movement therefore lands in the nearest
            // poster row; the utility remains reachable near its edge.
            if catalog.items.isEmpty {
                Text("No titles in this catalog.").font(.inter(.callout))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.58)).frame(height: 64)
                    .padding(.horizontal, horizontalPadding)
            } else {
                let shape = MediaArtShape.forItems(catalog.items)
                #if !os(tvOS)
                MobileLibraryShelf(items: catalog.items, shape: shape, onSelect: openHeroItem)
                #else
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: itemSpacing) {
                        ForEach(Array(catalog.items.enumerated()), id: \.element.libraryKey) { index, item in
                            Group {
                                if item.opensPage {
                                    #if os(tvOS)
                                    TVSelectable(drawsFocusChrome: false, action: { pushed = item },
                                                 onFocusChange: { focused in preview(item, when: focused) }) {
                                        MediaItemCard(item: item, shape: shape)
                                    }
                                    .tvHoldMenu(item.name, symbol: "film") { media.tvCardChoices(for: item) }
                                    #else
                                    NavigationLink(value: item) { MediaItemCard(item: item, shape: shape) }
                                        .lineupFlatButton()
                                    #endif
                                } else {
                                    #if os(tvOS)
                                    MediaPlayableCard(item: item, shape: shape,
                                        onFocusChange: { focused in preview(item, when: focused) })
                                    #else
                                    MediaPlayableCard(item: item, shape: shape)
                                    #endif
                                }
                            }
                            .frame(width: cardWidth(shape))
                            // The next few along, so a swipe finds them made.
                            .onAppear { prefetch(catalog.items, after: index, shape: shape) }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                .lineupFocusRegion()
                #endif
            }
        }
        .modifier(PhoneShelfPanel())
    }

    /// The cards just past one that has come into view.
    private func prefetch(_ items: [MediaItem], after index: Int, shape: MediaArtShape) {
        for next in (index + 1)..<min(items.count, index + 7) {
            let art = MediaItemCard.art(for: items[next], shape: shape, in: media)
            LineupArt.prefetch(art.url, pixels: art.pixels)
        }
    }

    private func openHeroItem(_ item: MediaItem) {
        if item.opensPage { pushed = item }
        else if item.isPlayable { heroPlayableItem = item }
    }

    #if os(tvOS)
    private func preview(_ item: MediaItem, when focused: Bool) {
        tvPreview.focus(item, focused: focused) { item in
            try? await media.details(of: item)
        }
    }

    private func rotateLibraryPreview() async {
        let candidates = heroItems
        guard candidates.count > 1 else { return }
        let current = min(heroIndex, candidates.count - 1)
        let nextIndex = (current + 1) % candidates.count
        let next = candidates[nextIndex]
        // Begin both upcoming downloads during this title's four-second dwell.
        for offset in [nextIndex, (nextIndex + 1) % candidates.count] {
            if let art = backdropArt(for: candidates[offset]) {
                LineupArt.prefetch(art.url, pixels: art.pixels)
            }
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: LibraryHeroRotation.interval) } catch { return }
            guard !Task.isCancelled, canRotateLibraryPreview else { return }
            // Keep the current picture while a slow download finishes.
            guard backdropIsReady(for: next) else {
                if let art = backdropArt(for: next) {
                    LineupArt.prefetch(art.url, pixels: art.pixels)
                }
                continue
            }
            showHero(at: nextIndex)
            return
        }
    }

    private var canRotateLibraryPreview: Bool {
        isVisible && scenePhase == .active && !voiceOver
            && !searchPresented && submittedQuery.isEmpty
            && pushed == nil && heroPlayableItem == nil
            && (tvFocus == nil || tvFocus == .hero)
    }

    // MARK: - The television's browser

    /// What can sit in the row at the foot of the screen, top to bottom.
    private var tvShelves: [TVLibraryShelf] {
        var shelves: [TVLibraryShelf] = []
        if !continueWatching.isEmpty {
            shelves.append(TVLibraryShelf(id: LibraryShelfOrder.continueWatching, title: "Continue Watching",
                                          label: nil, items: continueWatching.map(\.item),
                                          opensPages: true, catalog: nil))
        }
        shelves += media.builtInShelves.map { catalog in
            TVLibraryShelf(id: catalog.id, title: catalog.title, label: nil, items: catalog.items,
                           opensPages: false, catalog: catalog)
        }
        if !favoriteTitles.isEmpty {
            shelves.append(TVLibraryShelf(id: LibraryShelfOrder.favorites, title: "Favorites", label: nil,
                                          items: favoriteTitles, opensPages: false, catalog: nil))
        }
        if !favoriteEpisodes.isEmpty {
            shelves.append(TVLibraryShelf(id: LibraryShelfOrder.favoriteEpisodes, title: "Favorite Episodes",
                                          label: nil, items: favoriteEpisodes,
                                          opensPages: false, catalog: nil))
        }
        for catalog in catalogs {
            shelves.append(TVLibraryShelf(id: catalog.id, title: catalog.title,
                                          label: media.serverName(for: catalog), items: catalog.items,
                                          opensPages: false, catalog: catalog))
        }
        return media.arrangedShelves(shelves, id: \.id).map { shelf in
            TVLibraryShelf(id: shelf.id, title: media.shelfTitle(id: shelf.id, default: shelf.title),
                           label: shelf.label, items: shelf.items, opensPages: shelf.opensPages,
                           catalog: shelf.catalog)
        }
    }

    private var heroItems: [MediaItem] {
        media.heroCatalog.map { MediaHeroCatalogSelection.featuredItems(in: $0) } ?? []
    }

    private var heroItem: MediaItem? {
        let items = heroItems
        guard !items.isEmpty else { return nil }
        return items[min(heroIndex, items.count - 1)]
    }

    /// The artwork fills the screen. The title it shows is told in the top
    /// half, the hero's Play sits under that, and one shelf at a time is the
    /// row along the foot, its titles resting on the bottom edge. Up and down
    /// change which shelf is in that row rather than scrolling the screen.
    private var tvBrowser: some View {
        let shelves = tvShelves
        let index = min(shelfIndex, max(0, shelves.count - 1))
        let rowShape = shelves.indices.contains(index) ? MediaArtShape.forItems(shelves[index].items) : .poster
        let blockHeight = shelves.isEmpty ? 0 : tvShelfBlockHeight(for: rowShape)
        return GeometryReader { bounds in
            let heroHeight = max(0, bounds.size.height - blockHeight)
            let compact = heroHeight < 560
            VStack(spacing: 0) {
                VStack(spacing: compact ? 12 : 24) {
                    TVMediaLibraryPreview(item: tvPreview.item, steady: true, compact: compact)
                        .allowsHitTesting(false)
                    if !heroItems.isEmpty {
                        heroRow.lineupFocusRegion()
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight, alignment: .center)
                .clipped()
                if !shelves.isEmpty {
                    shelfBlock(shelves[index], index: index, count: shelves.count)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { shelfAboveStrip(shown: index > 0) }
                        .frame(height: blockHeight, alignment: .bottom)
                        .lineupFocusRegion()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // Behind, as a background: whatever the artwork and the words about
        // it measure, they are drawn in the screen's frame and can never
        // resize it. In the stack, a picture or a block of words taller than
        // the screen made the stack taller, and the whole screen -- shelf,
        // Play and artwork -- jumped as the remote moved between titles.
        .background { TVMediaLibraryCanvas(preview: tvPreview) }
        // Only the artwork may run behind the top navigation. Focusable
        // Library content must retain its top safe area.
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .onAppear { tabBar?.reset() }
        .onChange(of: tvFocus) { previous, place in
            if place == .shelfAbove { cameUpFromRow(previous) } else { tvFocusChanged(to: place) }
        }
        .onChange(of: shelves.count) { _, count in
            if shelfIndex >= count { shelfIndex = max(0, count - 1) }
        }
        .task(id: TVShelfPrefetchKey(index: index, count: shelves.count)) {
            await prefetchShelves(around: index)
        }
        .onChange(of: shelves.indices.contains(index) ? shelves[index].items.map(\.libraryKey) : []) { previous, current in
            // A held menu may temporarily clear focus. Follow the same show's
            // new episode even if other Continue Watching cards reordered.
            if shelves.indices.contains(index), shelves[index].id == LibraryShelfOrder.continueWatching,
               let old = lastFocusedCard, previous.contains(old.libraryKey), !current.contains(old.libraryKey),
               let server = old.serverID {
                let scope = LocalContinueWatchingDismissal(item: old, profileID: server)
                if let slot = shelves[index].items.firstIndex(where: {
                    scope.matches($0, profileID: $0.serverID ?? server)
                }) {
                    tvFocus = .card(slot)
                    tvFocusChanged(to: .card(slot))
                    return
                }
            }
            tvFocusChanged(to: tvFocus)
        }
    }

    /// The column the remote is on in a shelf, or was left on.
    private func column(in shelf: TVLibraryShelf) -> Int {
        if case .card(let slot)? = tvFocus { return slot }
        return shelfColumns[shelf.id] ?? 0
    }

    /// The cards whose art is fetched: what fits on screen from the column,
    /// with a few either side to meet the remote.
    private static func artWindow(around column: Int) -> ClosedRange<Int> {
        max(0, column - 4)...(column + 10)
    }

    /// The shelves either side of the one shown are fetched at once, so a
    /// press up or down finds their posters made; the first screenful of
    /// every other shelf follows when the network has had a moment.
    private func prefetchShelves(around index: Int) async {
        let shelves = tvShelves
        guard !shelves.isEmpty else { return }
        func fetch(_ shelf: TVLibraryShelf, _ window: ClosedRange<Int>) {
            let shape = MediaArtShape.forItems(shelf.items)
            for slot in window where shelf.items.indices.contains(slot) {
                let art = MediaItemCard.art(for: shelf.items[slot], shape: shape, in: media)
                LineupArt.prefetch(art.url, pixels: art.pixels)
            }
        }
        for neighbour in [index + 1, index - 1] where shelves.indices.contains(neighbour) {
            let shelf = shelves[neighbour]
            fetch(shelf, Self.artWindow(around: shelfColumns[shelf.id] ?? 0))
        }
        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
        for shelf in shelves { fetch(shelf, 0...7) }
    }

    /// A strip the width of the screen along the top of the shelf, there to be
    /// focused. Up from a card the focus engine moves on its own, to whatever
    /// is above; with an earlier shelf to go back to, this is the nearest
    /// thing above, so the engine lands here and the screen brings that shelf
    /// in (`cameUpFromRow`). On the first shelf it is not there, and up goes
    /// on to Play. From Play it is never there, so down goes to a card.
    private func shelfAboveStrip(shown: Bool) -> some View {
        // Faint enough not to be seen, but not clear: a fully transparent
        // view risks being passed over by the focus engine.
        Color.black.opacity(0.02)
            .frame(height: 4)
            .focusable(shown && tvFocus != .hero)
            .focused($tvFocus, equals: .shelfAbove)
            .focusEffectDisabled()
            .accessibilityHidden(true)
    }

    /// The row's height: its heading, the tallest card it can hold with that
    /// card's two lines of title, and the last of those resting a few points
    /// above the screen's edge.
    private func tvShelfBlockHeight(for shape: MediaArtShape) -> CGFloat {
        let width = cardWidth(shape)
        let art = width / shape.ratio
        let caption: CGFloat = 10 + 56
        let heading: CGFloat = 34 + 14
        return Self.tvShelfTop + heading + 16 + art + caption + 18
    }

    /// The hero's own control: Play, and left or right for the title before
    /// or after it.
    private var heroRow: some View {
        let item = tvPreview.item ?? heroItem
        let focused = tvFocus == .hero
        let count = heroItems.count
        let buttonShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 22) {
            HStack(spacing: 12) {
                LineupIconTile(symbol: "play.fill", size: 32)
                Text(item?.isSeries == true || item?.type == "Episode" ? "Play Series" : "Play Movie")
            }
            .font(.inter(20, .semibold))
            .foregroundStyle(focused ? LineupStyle.background : LineupStyle.text)
            .padding(.horizontal, 30).frame(height: 58)
            .background(focused ? LineupStyle.text : LineupStyle.text.opacity(0.14), in: buttonShape)
            .overlay(buttonShape.strokeBorder(LineupStyle.text.opacity(focused ? 0 : 0.28), lineWidth: 1))
            .scaleEffect(focused ? LineupStyle.controlLift : 1)
            .lineupShadow(.lifted, on: focused)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
            .contentShape(buttonShape)
            .focusable()
            .focused($tvFocus, equals: .hero)
            .focusEffectDisabled()
            .tvSelectAction { playHero() }
            .onMoveCommand { moveTV($0, from: .hero) }
            .tvHoldMenu(item?.name ?? "", symbol: "info.circle") {
                guard let item, item.opensPage else { return [] }
                return [TVChoice("Details", symbol: "info.circle") { pushed = item }]
                    + media.tvCardChoices(for: item)
            }
            .accessibilityLabel(item.map { "Play \($0.name)" } ?? "Play")
            if count > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                    Text("\(min(heroIndex, count - 1) + 1) of \(count)")
                        .font(.interDigits(16, .semibold))
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(LineupStyle.text.opacity(focused ? 0.8 : 0.45))
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func shelfBlock(_ shelf: TVLibraryShelf, index: Int, count: Int) -> some View {
        let shape = MediaArtShape.forItems(shelf.items)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                TVShelfTitle(title: shelf.title, symbol: Self.shelfSymbol(shelf.id))
                if let label = shelf.label {
                    HStack(spacing: 7) {
                        if let brand = shelf.catalog.flatMap(media.serverBrand(for:)) {
                            MediaServerLogo(brand: brand).frame(width: 16, height: 16)
                        }
                        Text(label.uppercased())
                            .font(.inter(10, .bold)).tracking(1.2)
                            .foregroundStyle(LineupStyle.lightPurple.opacity(0.42))
                            .lineLimit(1)
                    }
                }
                Spacer()
                // Where this shelf is among them, and that up and down move
                // through the rest.
                HStack(spacing: 10) {
                    Image(systemName: "chevron.up").opacity(index > 0 ? 1 : 0.3)
                    Text("\(index + 1) of \(count)").font(.interDigits(15, .semibold))
                    Image(systemName: "chevron.down").opacity(index < count - 1 ? 1 : 0.3)
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
                .accessibilityHidden(true)
            }
            .id(shelf.id)
            .transition(.opacity.combined(with: .offset(y: shelfStepDown ? 18 : -18)))
            .padding(.horizontal, horizontalPadding)
            // On the artwork itself, with no panel behind it: a soft shadow
            // keeps the heading read over a bright picture.
            .shadow(color: .black.opacity(0.55), radius: 10, y: 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: itemSpacing) {
                        // Slots by position, so a change of shelf refills
                        // them and the one the remote is on stays put.
                        ForEach(Array(shelf.items.enumerated()), id: \.offset) { slot, item in
                            tvCard(item, slot: slot, shelf: shelf, shape: shape)
                                .frame(width: cardWidth(shape))
                                .id(slot)
                        }
                        if let catalog = shelf.catalog {
                            seeAllTile(catalog, slot: shelf.items.count, shape: shape)
                                .frame(width: cardWidth(shape))
                                .id(shelf.items.count)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                .scrollClipDisabled()
                // Along the row the focus engine keeps the card in view by
                // itself; scrolling here as well, on every press, moved the
                // row twice and made it drag behind the remote. Only a new
                // shelf, which lands on the card it was left on, is brought
                // to it.
                .onChange(of: shelf.id) { _, id in
                    proxy.scrollTo(shelfColumns[id] ?? 0)
                }
            }
        }
        .padding(.top, Self.tvShelfTop)
        .padding(.bottom, 18)
        // No panel: the shelf sits straight on the full-screen artwork, its
        // heading and cards over the picture, which the backdrop's shade
        // darkens toward the foot.
    }

    /// Between the hero's Play and the shelf's heading.
    private static let tvShelfTop: CGFloat = 10

    private func tvCard(_ item: MediaItem, slot: Int, shelf: TVLibraryShelf, shape: MediaArtShape) -> some View {
        let focused = tvFocus == .card(slot)
        return MediaItemCard(item: item, shape: shape)
            // Every card in the row is built, so focus can land on any of
            // them; only those near where the remote is fetch their art.
            .environment(\.lineupArtDeferred, !Self.artWindow(around: column(in: shelf)).contains(slot))
            .id(item.libraryKey)
            .transition(.opacity.combined(with: .offset(y: shelfStepDown ? 24 : -24)))
            .environment(\.lineupTVSelectableFocused, focused)
            .contentShape(Rectangle())
            .focusable()
            .focused($tvFocus, equals: .card(slot))
            .focusEffectDisabled()
            .tvSelectAction { activate(item, in: shelf) }
            .onMoveCommand { moveTV($0, from: .card(slot)) }
            .scaleEffect(focused ? LineupStyle.cardLift : 1)
            .zIndex(focused ? 10 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
            .tvHoldMenu(item.name, symbol: item.type == "Episode" ? "tv" : "film") { media.tvCardChoices(for: item) }
    }

    /// The end of a catalog's row: the whole catalog, and holding Select to
    /// take the shelf away.
    private func seeAllTile(_ catalog: MediaCatalog, slot: Int, shape: MediaArtShape) -> some View {
        let focused = tvFocus == .card(slot)
        let tile = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(spacing: 10) {
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(shape.ratio, contentMode: .fit)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 34, weight: .semibold, design: .rounded))
                        Text("See All").font(.inter(20, .semibold))
                    }
                    .foregroundStyle(LineupStyle.lightPurple)
                }
                .background(LineupStyle.surface.opacity(0.8), in: tile)
                .overlay(tile.stroke(LineupStyle.line, lineWidth: 1))
                .lineupFocusLayer(focused, in: tile)
            Text(" ").font(.inter(22, .semibold)).lineLimit(2, reservesSpace: true)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($tvFocus, equals: .card(slot))
        .focusEffectDisabled()
        .tvSelectAction { pushed = catalog.root }
        .onMoveCommand { moveTV($0, from: .card(slot)) }
        .scaleEffect(focused ? LineupStyle.cardLift : 1)
        .zIndex(focused ? 10 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
        .tvHoldMenu(media.shelfTitle(catalog), symbol: "rectangle.stack") {
            [TVChoice("Remove Shelf", symbol: "minus.rectangle", isDestructive: true) {
                media.removeShelf(catalog)
            }]
        }
        .accessibilityLabel("See all of \(catalog.title)")
    }

    /// Only what the focus engine can't do: left and right on Play turn
    /// through the hero's titles, and down from a card, where there is
    /// nothing below, brings in the next shelf. Everything else -- along the
    /// row, up to Play and the Library button, down from Play -- is the
    /// engine's. tvOS moves focus for a press and calls this as well, so a
    /// handler that moved focus where the engine could go moved it twice.
    private func moveTV(_ direction: MoveCommandDirection, from place: TVLibraryFocus) {
        switch (place, direction) {
        case (.hero, .left): stepHero(by: -1)
        case (.hero, .right): stepHero(by: 1)
        case (.card(let slot), .down):
            let shelves = tvShelves
            guard !shelves.isEmpty else { return }
            let index = min(shelfIndex, shelves.count - 1)
            if index < shelves.count - 1 { changeShelf(to: index + 1, from: slot, in: shelves) }
        default:
            break
        }
    }

    /// Up from a card onto the strip above the row: the shelf before comes
    /// in, at the card it was left on. From anywhere else the strip is
    /// passed straight through to the shelf in the row.
    private func cameUpFromRow(_ previous: TVLibraryFocus?) {
        let shelves = tvShelves
        guard !shelves.isEmpty else { return }
        let index = min(shelfIndex, shelves.count - 1)
        if case .card(let slot)? = previous, index > 0 {
            changeShelf(to: index - 1, from: slot, in: shelves)
        } else {
            focusShelf(at: index, in: shelves)
        }
    }

    private func changeShelf(to index: Int, from slot: Int, in shelves: [TVLibraryShelf]) {
        shelfColumns[shelves[min(shelfIndex, shelves.count - 1)].id] = slot
        shelfStepDown = index > shelfIndex
        withAnimation(.easeOut(duration: 0.22)) { shelfIndex = index }
        focusShelf(at: index, in: shelves)
    }

    /// Onto a shelf at the card it was left on, or its first.
    private func focusShelf(at index: Int, in shelves: [TVLibraryShelf]) {
        let shelf = shelves[index]
        let slots = shelf.items.count + (shelf.catalog == nil ? 0 : 1)
        guard slots > 0 else { return }
        let place = TVLibraryFocus.card(min(shelfColumns[shelf.id] ?? 0, slots - 1))
        tvFocus = place
        // The same slot on another shelf is the same focus value, which
        // changes nothing for onChange to see; the preview is told here.
        tvFocusChanged(to: place)
    }

    private func stepHero(by step: Int) {
        let count = heroItems.count
        guard count > 1 else { return }
        showHero(at: (heroIndex + step + count) % count)
    }

    private func showHero(at index: Int) {
        let items = heroItems
        guard items.indices.contains(index) else { return }
        heroIndex = index
        withAnimation(LibraryHeroRotation.animation(reduceMotion: reduceMotion)) {
            tvPreview.rotate(to: items[index]) { item in try? await media.details(of: item) }
        }
    }

    /// The preview follows the remote: the card it is on, or the hero's
    /// title when it is back on Play.
    private func tvFocusChanged(to place: TVLibraryFocus?) {
        if let card = focusedCard {
            preview(card, when: false)
            focusedCard = nil
        }
        switch place {
        case .card(let slot)?:
            let shelves = tvShelves
            guard !shelves.isEmpty else { return }
            let shelf = shelves[min(shelfIndex, shelves.count - 1)]
            guard shelf.items.indices.contains(slot) else { return }
            let item = shelf.items[slot]
            // A service is no title: the room behind keeps what it shows.
            guard StreamingService.service(for: item) == nil else { return }
            focusedCard = item
            lastFocusedCard = item
            preview(item, when: true)
            // The titles either side, so the artwork is made before the
            // remote gets there.
            for neighbour in [slot - 1, slot + 1] where shelf.items.indices.contains(neighbour) {
                if let art = backdropArt(for: shelf.items[neighbour]) {
                    LineupArt.prefetch(art.url, pixels: art.pixels)
                }
            }
        case .hero?:
            if let heroItem, tvPreview.item?.libraryKey != heroItem.libraryKey {
                showHero(at: heroIndex)
            }
        case .shelfAbove?, nil:
            break
        }
    }

    private func activate(_ item: MediaItem, in shelf: TVLibraryShelf) {
        if let page = pageItem(for: item, opensPages: shelf.opensPages) { pushed = page }
        else { play(item) }
    }

    /// A film plays; a show plays its next episode, or opens its page when
    /// there is none to play yet.
    private func playHero() {
        guard let item = tvPreview.item ?? heroItem else { return }
        if item.isSeries {
            Task {
                if let next = await media.resumeEpisode(in: item) { play(next) } else { pushed = item }
            }
        } else if item.isPlayable {
            play(item)
        } else {
            pushed = item
        }
    }

    private func play(_ item: MediaItem) {
        if let playMedia { playMedia(item) } else { heroPlayableItem = item }
    }

    private func backdropIsReady(for item: MediaItem) -> Bool {
        guard let art = backdropArt(for: item) else { return true }
        return LineupArt.isResolved(art.url, pixels: art.pixels)
    }

    private func backdropArt(for item: MediaItem) -> (url: URL, pixels: Int)? {
        guard let url = media.backdropURL(for: item, width: 1920)
            ?? media.imageURL(for: item, width: 1920) else { return nil }
        return (url, LineupArt.pixels(for: 1920))
    }

    #endif

    private func clearSearch() {
        query = ""
        submittedQuery = ""
        results = []
        searchError = nil
        searchRequestID = UUID()
    }

    /// Local rows use the same cards, spacing and focus regions as server
    /// shelves. They should look like part of the Library, not a utility panel
    /// bolted above it.
    ///
    /// Continue Watching opens pages rather than streams: a film's own, and an
    /// episode's show's, at that episode's season. If the app has the viewer
    /// on the wrong episode, the right one is a choice away on that page.
    private func localShelf(id: String, title: String, items: [MediaItem], opensPages: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: shelfStackSpacing) {
            #if os(tvOS)
            HStack(alignment: .firstTextBaseline) {
                TVShelfTitle(title: title, symbol: Self.shelfSymbol(id))
                Spacer()
            }
            .padding(.horizontal, horizontalPadding)
            .lineupFocusRegion()
            #else
            PhoneShelfHeader(title: title, symbol: Self.shelfSymbol(id)) { EmptyView() }
            #endif
            let shape = MediaArtShape.forItems(items)
            #if !os(tvOS)
            MobileLibraryShelf(items: items, shape: shape) { item in
                if let page = pageItem(for: item, opensPages: opensPages) { pushed = page }
                else { heroPlayableItem = item }
            }
            #else
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: itemSpacing) {
                    ForEach(items, id: \.libraryKey) { trackedItem in
                        Group {
                            if let page = pageItem(for: trackedItem, opensPages: opensPages) {
                                #if os(tvOS)
                                TVSelectable(drawsFocusChrome: false, action: { pushed = page },
                                             onFocusChange: { focused in preview(trackedItem, when: focused) }) {
                                    MediaItemCard(item: trackedItem, shape: shape)
                                }
                                .tvHoldMenu(trackedItem.name, symbol: "play.circle") { media.tvCardChoices(for: trackedItem) }
                                #else
                                MediaItemCard(item: trackedItem, shape: shape)
                                    .lineupHoldMenu(trackedItem.name, symbol: "play.circle",
                                                    items: { media.cardMenuItems(for: trackedItem) }) {
                                        pushed = page
                                    }
                                #endif
                            } else {
                                #if os(tvOS)
                                MediaPlayableCard(item: trackedItem, shape: shape,
                                    onFocusChange: { focused in preview(trackedItem, when: focused) })
                                #else
                                MediaPlayableCard(item: trackedItem, shape: shape)
                                #endif
                            }
                        }
                        .frame(width: cardWidth(shape))
                    }
                }
                .padding(.vertical, 8)
            }
            .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
            .lineupFocusRegion()
            #endif
        }
        .modifier(PhoneShelfPanel())
    }

    /// The page a local row's card opens, or nil for a card that goes
    /// straight to its streams. An episode with no show to name keeps going
    /// to its streams: there is no page to open it at.
    private func pageItem(for item: MediaItem, opensPages: Bool) -> MediaItem? {
        guard opensPages else { return item.opensPage ? item : nil }
        if item.type == "Episode" { return media.series(of: item) }
        return item.opensPage || item.isPlayable ? item : nil
    }

    /// The field lives here rather than on the shelf screen. tvOS draws its own
    /// heavy treatment around a focused text field, and that is the one frame
    /// this app cannot restyle, so it is kept off the screen behind it.
    private var searchSheet: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 24) {
            Text("Search").font(.inter(34, .semibold))
            TextField("Movies and shows", text: $query)
                .textFieldStyle(.plain)
                .font(.inter(24))
                .onSubmit { submitSearch() }
            HStack(spacing: 14) {
                TVSelectable(scale: LineupStyle.controlLift, action: {
                    submitSearch()
                }) {
                    Text("Done").font(.inter(17, .semibold))
                        .padding(.horizontal, 22).frame(height: 52)
                        .modifier(MediaChromeSurface(prominent: true, radius: 12))
                }
                TVSelectable(scale: LineupStyle.controlLift, action: {
                    clearSearch()
                    searchPresented = false
                }) {
                    Text("Clear").font(.inter(17, .semibold))
                        .padding(.horizontal, 22).frame(height: 52)
                        .modifier(MediaChromeSurface(radius: 12))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        #else
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Search your connected libraries for movies, shows, and episodes.")
                    .font(.inter(.subheadline)).foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").opacity(0.58)
                    TextField("Movies and shows", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { submitSearch() }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .lineupFlatButton()
                    }
                }
                .font(.inter(.body)).padding(.horizontal, 16).frame(height: 50)
                .modifier(MediaChromeSurface(focused: searchFocused, outline: true, radius: 13))
                Button(action: submitSearch) {
                    Label("Search", systemImage: "magnifyingglass")
                        .font(.inter(.body, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1))
                }
                .lineupFlatButton().disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(LineupStyle.background.ignoresSafeArea())
            .foregroundStyle(LineupStyle.lightPurple)
            .navigationTitle("Search Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LineupToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { searchPresented = false }
                        .buttonStyle(LineupBarButtonStyle())
                }
            }
            .onAppear { searchFocused = true }
        }
        .presentationDetents([.medium])
        #endif
    }

    private func submitSearch() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searching = !value.isEmpty
        submittedQuery = value
        searchRequestID = UUID()
        searchPresented = false
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        54
        #else
        LineupPanelStyle.inset
        #endif
    }
    private var catalogSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        LineupPanelStyle.gap
        #endif
    }
    /// Header to cards. The phone's header carries its own padding and
    /// hairline, so the gap under it is the cards' own.
    private var shelfStackSpacing: CGFloat {
        #if os(tvOS)
        14
        #else
        6
        #endif
    }

    /// Each shelf's icon in its panel header, by what the shelf is rather
    /// than what it is called, since any shelf can be renamed.
    static func shelfSymbol(_ id: String) -> String {
        switch id {
        case LibraryShelfOrder.continueWatching: "play.circle"
        case LibraryShelfOrder.favorites: "heart"
        case LibraryShelfOrder.favoriteEpisodes: "heart.text.square"
        case LibraryTrendingRow.movies.id, LibraryTrendingRow.shows.id: "flame"
        case StreamingService.rowID: "tv"
        default: id.hasPrefix("mdblist:") ? "list.star" : "rectangle.stack"
        }
    }
    private var itemSpacing: CGFloat {
        #if os(tvOS)
        22
        #else
        14
        #endif
    }
    // A still is landscape, so the same width that suits a poster would leave it
    // a sliver. Each shape gets the width that reads at its own proportions.
    private func cardWidth(_ shape: MediaArtShape) -> CGFloat {
        #if os(tvOS)
        shape == .poster ? 230 : 360
        #else
        shape == .poster ? 150 : 232
        #endif
    }
    private var sectionTitleFont: Font {
        #if os(tvOS)
        .inter(24, .heavy)
        #else
        .inter(.title3, .heavy)
        #endif
    }
    private var sectionTitleFontSize: CGFloat {
        #if os(tvOS)
        24
        #else
        20
        #endif
    }
}

#if !os(tvOS)
/// A Library shelf's header in its panel: icon and caption over a hairline,
/// with the server and See All on the right.
struct PhoneShelfHeader<Accessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 0) {
            LineupPanelHeader(title: title, systemImage: symbol) {
                HStack(spacing: 10) { accessory() }
            }
            .padding(.top, 12).padding(.bottom, 8)
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
        }
        .padding(.horizontal, LineupPanelStyle.inset)
    }
}
#endif

#if os(tvOS)
/// A shelf's title on the television: the panels' icon and heavy caption in
/// light grey, at the size it is read at across a room.
struct TVShelfTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            LineupIconTile(symbol: symbol, size: LineupPanelStyle.headerSize * 1.6)
            Text(title.uppercased())
                .font(.inter(LineupPanelStyle.headerSize + 2, .heavy))
                .tracking(LineupPanelStyle.headerTracking)
        }
        .foregroundStyle(LineupPanelStyle.caption)
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)
    }
}
#endif

/// Details use the same dark panels as the updated app presentations.
struct PhoneDetailPanel: ViewModifier {
    var bottom: CGFloat = 6
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LineupPresentationStyle.card, in: LineupPanelStyle.shape)
            .overlay(LineupPanelStyle.shape.strokeBorder(LineupPresentationStyle.border, lineWidth: 0.7))
            .padding(.horizontal, LineupPanelStyle.margin)
        #endif
    }
}

/// Main Library shelves keep their existing approved panel appearance.
struct PhoneShelfPanel: ViewModifier {
    /// Under the last row: posters bring 8 of their own, other rows none.
    var bottom: CGFloat = 6

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
            .padding(.horizontal, LineupPanelStyle.margin)
        #endif
    }
}

#if !os(tvOS)
/// Where the Seasons button is, so its dropdown can hang from it.
struct MediaSeasonMenuAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
#endif

#if !os(tvOS)
/// Under the hero while no media server is connected: the built-in rows are
/// there to browse, and this is where playing them starts.
struct MobileAddServerPrompt: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaServerLogoRow(size: 24)
            Text("Add a media server to play these")
                .font(.inter(.headline, .semibold)).foregroundStyle(LineupStyle.text)
            Text("Connect Jellyfin, Emby, Plex or Silo. Until then, every title shows its details but can't play.")
                .font(.inter(.subheadline)).foregroundStyle(LineupPresentationStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Media Server", action: action).lineupProminentButton()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineupPresentationSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
#endif
