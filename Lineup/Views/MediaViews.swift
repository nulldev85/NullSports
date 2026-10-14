import SwiftUI
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
    @EnvironmentObject private var media: MediaLibrary
    @State private var addingServer = false
    @State private var choosingShelf = false
    @State private var reorderingShelves = false
    @State private var clearingHistory = false
    @State private var searchingLibrary = false
    @State private var playing: MediaPlayRequest?
    /// The Library's options, dropped from the bar's ellipsis.
    @State private var optionsOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        stack
            .environment(\.playMedia, MediaPlayAction { playing = MediaPlayRequest(item: $0) })
            #if os(tvOS)
            .fullScreenCover(item: $playing) { request in MediaSourcePicker(item: request.item) }
            #else
            .sheet(item: $playing) { request in MediaSourcePicker(item: request.item) }
            #endif
    }

    private var stack: some View {
        NavigationStack {
            Group {
            #if os(tvOS)
            TVMediaServersHome(addingServer: $addingServer, choosingShelf: $choosingShelf,
                               reorderingShelves: $reorderingShelves,
                               searchingLibrary: $searchingLibrary)
            #else
            Group {
                if !media.hasAnySource {
                    ContentUnavailableView {
                        Label {
                            Text("Add a Media Server")
                        } icon: {
                            MediaServerLogoRow(size: 40)
                        }
                    } description: {
                        Text("Connect a Jellyfin, Emby or Plex server to watch your own library here.")
                    } actions: {
                        Button("Add Media Server", systemImage: "plus") { addingServer = true }
                    }
                } else if media.roots.isEmpty && media.isLoading {
                    ProgressView("Loading libraries…")
                } else if media.shelves.isEmpty && media.loadFailed {
                    // Not "Choose Your Shelves". An attempt that failed and a
                    // server with nothing selected look identical from here,
                    // and telling a viewer to pick shelves that could not be
                    // fetched sends them looking for a setting to fix.
                    ContentUnavailableView {
                        Label(media.profiles.count > 1 ? "Can't Reach Your Servers" : "Can't Reach Your Server",
                              systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(media.profiles.count > 1
                             ? "Lineup couldn't load your libraries. Check that your servers are running and reachable from this network."
                             : "Lineup couldn't load your libraries. Check that the server is running and reachable from this network.")
                    } actions: {
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            Task { await media.reload() }
                        }
                    }
                } else {
                    MediaCatalogsScreen(catalogs: media.shelves, searchPresented: $searchingLibrary)
                }
            }
            .background(LineupStyle.background.ignoresSafeArea())
            .overlay {
                MobileDropdownLayer(isPresented: optionsOpen, title: "Library", symbol: "rectangle.stack",
                                    sections: optionsSections) { setOptions(false) }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    MobileDropdownButton(isOpen: optionsOpen, label: "Library options") {
                        setOptions(!optionsOpen)
                    }
                }
            }
            #endif
            }
            .sheet(isPresented: $addingServer) {
                MediaServerSetupView()
                    .environmentObject(media)
                    .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $choosingShelf) {
                MediaShelfPicker().environmentObject(media)
            }
            .sheet(isPresented: $reorderingShelves) {
                LibraryShelfOrderSheet().environmentObject(media)
                    .preferredColorScheme(.dark)
            }
            // Not `.task`. A task belongs to the view, and this work does not:
            // leaving the tab mid-load used to cancel it and leave the tab
            // stuck on its spinner. The store owns the load and decides whether
            // one is needed; appearing only asks.
            .onAppear {
                media.loadShelvesIfNeeded()
                // The IPTV provider's list is read ahead, for its shelves and
                // so the first title played does not wait on all of it.
                Task { await media.loadProviderShelves() }
                media.providerVOD.prefetch()
            }
            .onChange(of: media.profiles.map(\.id)) { _, _ in media.loadShelvesIfNeeded() }
            .alert("Media Server", isPresented: Binding(
                get: { media.errorMessage != nil },
                set: { if !$0 { media.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(media.errorMessage ?? "Unknown error") }
            .confirmationDialog("Clear local tracking?", isPresented: $clearingHistory,
                                titleVisibility: .visible) {
                Button("Clear Local Tracking", role: .destructive) { media.clearLocalPlayback() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes Continue Watching and local watched status from this device.")
            }
        }
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
        // Inside a Settings panel, a well a step lighter than the panel,
        // rounded to sit inside its corners.
        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
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
    @EnvironmentObject private var library: SportsLibrary
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
    @EnvironmentObject private var media: MediaLibrary
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
            Label(title, systemImage: symbol)
                .font(.inter(.subheadline, .semibold))
                .frame(maxWidth: .infinity, minHeight: 66)
                .lineupLiquidGlass(Capsule(), fallback: LineupStyle.raised, border: LineupStyle.line)
                .lineupFocusLayer(focused, in: Capsule())
                .scaleEffect(focused ? LineupStyle.controlLift : 1)
            #else
            // An unchosen chip's outline in the accent, dimmed while
            // unavailable.
            Label(title, systemImage: symbol)
                .font(.inter(.subheadline, .bold))
                .foregroundStyle(LineupStyle.highlight)
                .frame(maxWidth: .infinity, minHeight: 36)
                .overlay(Capsule().strokeBorder(LineupStyle.highlight, lineWidth: 1.5))
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
private struct TVMediaServersHome: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.tvTabBar) private var tabBar
    @Binding var addingServer: Bool
    @Binding var choosingShelf: Bool
    @Binding var reorderingShelves: Bool
    @Binding var searchingLibrary: Bool
    @State private var removingShelf = false
    @State private var clearingHistory = false

    /// Whether the shelves are on screen, with the Library's menu at the top
    /// right of the artwork above them; elsewhere the menu sits at the top.
    private var showsShelves: Bool { media.hasAnySource && !media.roots.isEmpty }

    /// Everything the Library's menu offers, in the order it lists it.
    private var options: [TVLibraryOption] {
        var options: [TVLibraryOption] = []
        if !media.shelves.isEmpty {
            options.append(TVLibraryOption(title: "Search the Library", symbol: "magnifyingglass") {
                searchingLibrary = true
            })
        }
        options.append(TVLibraryOption(title: "Add Shelf", symbol: "plus.rectangle.on.rectangle") {
            choosingShelf = true
        })
        if !media.removableShelves.isEmpty {
            options.append(TVLibraryOption(title: "Remove a Shelf", symbol: "minus.rectangle") {
                removingShelf = true
            })
        }
        if media.libraryRows.count > 1 {
            options.append(TVLibraryOption(title: "Edit Shelves", symbol: "arrow.up.arrow.down") {
                reorderingShelves = true
            })
        }
        if !media.isLoading {
            options.append(TVLibraryOption(title: "Refresh", symbol: "arrow.clockwise") {
                Task { await media.reload() }
            })
        }
        options.append(TVLibraryOption(title: "Add Server", symbol: "plus") { addingServer = true })
        if !media.continueWatching.isEmpty || !media.watchHistory.isEmpty {
            options.append(TVLibraryOption(title: "Clear Local Tracking", symbol: "trash", destructive: true) {
                clearingHistory = true
            })
        }
        return options
    }

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
                         ? "Refresh your servers, or confirm these accounts can access a library."
                         : "Refresh the server, or confirm this account can access a library.")
                        .font(.inter(.callout)).opacity(0.68)
                }
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaCatalogsScreen(catalogs: media.shelves, searchPresented: $searchingLibrary,
                                    options: options)
            }
        }
        .overlay(alignment: .top) {
            // Only where there are no shelves to hang it above: while the
            // libraries load, or when none are found.
            if !showsShelves && media.hasAnySource {
                TVLibraryMenuBar(options: options).padding(.top, 18)
            }
        }
        // Back on the Library's own screen: no title's page is over it, so
        // the tab bar is up whatever the pages that closed did or did not say.
        .onAppear { tabBar?.reset() }
        .confirmationDialog("Remove a Shelf", isPresented: $removingShelf, titleVisibility: .visible) {
            ForEach(media.removableShelves) { shelf in
                Button(media.shelfName(shelf), role: .destructive) { media.removeShelf(shelf) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its titles stay on your server; only the shelf leaves the Library.")
        }
        .confirmationDialog("Clear local tracking?", isPresented: $clearingHistory,
                            titleVisibility: .visible) {
            Button("Clear Local Tracking", role: .destructive) { media.clearLocalPlayback() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes Continue Watching and local watched status from this Apple TV.")
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

/// One thing the Library's menu offers.
struct TVLibraryOption: Identifiable {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
    var id: String { title }
}

/// The Library's menu: one button at the right of the screen that drops a
/// list of the Library's actions beneath it.
///
/// A row of chips across the top of the shelves scrolled up over the title
/// being previewed and covered its overview. One button at the right keeps
/// clear of the preview, which is drawn from the left, and the whole width
/// is one focus region, so pressing up from anywhere on the first shelf
/// still lands on it.
private struct TVLibraryMenuBar: View {
    let options: [TVLibraryOption]
    /// Told when the list opens and closes, so the screen can keep focus off
    /// everything under it while it is open: a press in the list that the
    /// focus engine carried onto a poster below closed the list under the
    /// viewer.
    var onOpenChange: (Bool) -> Void = { _ in }
    @State private var open = false
    /// Where focus is in the menu: its button, one of its rows, or nil once
    /// it is somewhere else on the screen.
    @FocusState private var focus: Place?

    private enum Place: Hashable {
        case button
        case row(Int)
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            button
                .overlay(alignment: .topTrailing) {
                    if open {
                        panel
                            .alignmentGuide(.top) { $0[.top] - 64 }
                            .transition(.opacity.combined(with: .offset(y: -8)))
                    }
                }
        }
        .padding(.horizontal, 54)
        .lineupFocusRegion()
        .onExitCommand(perform: open ? { close() } : nil)
        // Focus gone from the button and every row: the list closes behind it.
        .onChange(of: focus) { _, place in
            if place == nil, open { open = false }
        }
        .onChange(of: open) { _, isOpen in onOpenChange(isOpen) }
        .animation(.easeOut(duration: 0.16), value: open)
    }

    // A pill in the panels' own grey, as the phone's Sports menu opens
    // from: its tile, its name and a chevron, a step lighter while open.
    private var button: some View {
        HStack(spacing: 12) {
            LineupIconTile(symbol: "slider.horizontal.3", size: 34)
            Text("Library").font(.inter(19, .semibold))
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(LineupPanelStyle.quiet)
        }
        .foregroundStyle(LineupStyle.text)
        .padding(.leading, 9).padding(.trailing, 20)
        .frame(height: 52)
        .background(open ? LineupPanelStyle.well : LineupPanelStyle.fill, in: Capsule())
        .modifier(TVMenuFocus(focused: focus == .button, scale: LineupStyle.controlLift, radius: 26))
        .focusable()
        .focused($focus, equals: .button)
        .focusEffectDisabled()
        .onTapGesture {
            if open { close() } else { open = true }
        }
        // While the list is open, down leads into it. Up the focus engine
        // takes to the tab bar, and the list closes behind it.
        .onMoveCommand(perform: open ? { direction in
            switch direction {
            case .down: focus = .row(0)
            case .up: open = false
            default: close()
            }
        } : nil)
        .accessibilityLabel("Library options")
    }

    // A panel like every other: its header and hairline inside it, then a
    // row a choice, each with its coloured tile.
    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            LineupPanelHeader("Library", systemImage: "rectangle.stack")
                .padding(.horizontal, 22)
                .frame(width: 400, height: 62, alignment: .leading)
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                .padding(.horizontal, 22)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    HStack(spacing: 16) {
                        LineupIconTile(symbol: option.symbol, size: 38)
                        Text(option.title)
                        Spacer(minLength: 0)
                    }
                    .font(.inter(19, .semibold))
                    .foregroundStyle(option.destructive ? LineupIconTile.red : LineupStyle.text)
                    .padding(.horizontal, 14)
                    .frame(width: 384, height: 60)
                    .modifier(TVMenuFocus(focused: focus == .row(index), scale: 1.02, radius: 16))
                    .focusable()
                    .focused($focus, equals: .row(index))
                    .focusEffectDisabled()
                    .onTapGesture { choose(option) }
                    .onMoveCommand { direction in move(direction, from: index) }
                }
            }
            .padding(8)
        }
        .background(LineupPanelStyle.fill, in: shape)
        // It floats over panels of its own colour: a hairline of light round
        // its edge and a deep shadow under it.
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 34, y: 18)
        .fixedSize()
        .onAppear { focus = .row(0) }
    }

    /// One row a press. tvOS moves focus for the press as well as calling
    /// this, so the target is the row next to the one the handler sits on --
    /// the row the engine goes to, so the two agree. Worked out from where
    /// focus already was after the engine's move, every press went two rows.
    /// The screen keeps everything under the list unfocusable while it is
    /// open (`onOpenChange`), so the engine has nowhere else to go.
    private func move(_ direction: MoveCommandDirection, from index: Int) {
        switch direction {
        case .down: focus = .row(min(index + 1, options.count - 1))
        case .up: focus = index == 0 ? .button : .row(index - 1)
        default: break
        }
    }

    private func choose(_ option: TVLibraryOption) {
        close()
        option.action()
    }

    /// Back to the button before the list goes, so focus never falls loose
    /// onto whatever was under it.
    private func close() {
        focus = .button
        open = false
    }
}

/// The app's focus look -- the light layer, a lift and a shadow -- for a
/// control that keeps its focus in a parent's `FocusState` rather than its
/// own, as the Library menu's button and rows do.
private struct TVMenuFocus: ViewModifier {
    let focused: Bool
    let scale: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .environment(\.lineupTVSelectableFocused, focused)
            .contentShape(Rectangle())
            .lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: -6))
            .scaleEffect(focused ? scale : 1)
            .lineupShadow(.lifted, on: focused)
            .zIndex(focused ? 10 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
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

private struct TVMediaHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderLabel(configuration: configuration)
    }
    private struct HeaderLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: ButtonStyle.Configuration
        var body: some View {
            configuration.label
                .font(.inter(16, .semibold))
                .foregroundStyle(LineupStyle.lightPurple)
                .padding(.horizontal, 14).frame(minHeight: 42)
                .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .scaleEffect(focused ? LineupStyle.controlLift : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: focused)
        }
    }
}
#endif

private struct MediaCatalogsScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let catalogs: [MediaCatalog]
    @Binding var searchPresented: Bool
    #if os(tvOS)
    /// What the Library's menu offers, at the right above the shelves.
    var options: [TVLibraryOption]? = nil
    #endif
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
    #if os(tvOS)
    @StateObject private var tvPreview = TVMediaPreviewState()
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
    /// While the Library menu is open, Play and the shelf can't take focus,
    /// so a press in the list can't land on them and close it.
    @State private var menuOpen = false
    @State private var focusedCard: MediaItem?
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
                        ContentUnavailableView("Search Unavailable", systemImage: "exclamationmark.triangle", description: Text(searchError))
                    } else if results.isEmpty {
                        ContentUnavailableView("No Results", systemImage: "magnifyingglass",
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
                    VStack(spacing: 0) {
                        #if os(tvOS)
                        if let options {
                            TVLibraryMenuBar(options: options)
                                .padding(.top, 40)
                                .zIndex(1)
                        }
                        #endif
                        ContentUnavailableView("Choose Your Shelves", systemImage: "rectangle.stack.badge.plus",
                            description: Text("Trending Movies, Trending Shows and Streaming Services appear here in a moment. Add any other shelf you want from Add Shelf."))
                    }
                } else {
                    #if os(tvOS)
                    tvBrowser
                    #else
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: catalogSpacing) {
                            if let heroCatalog = media.heroCatalog {
                                // The first panel starts a gap below the
                                // hero, as each starts a gap below the last.
                                MediaLibraryHero(catalog: heroCatalog, onOpen: openHeroItem)
                            }
                            libraryShelves
                        }
                        .padding(.bottom, 44)
                    }
                    .ignoresSafeArea(edges: .top)
                    .task(id: catalogs.map(\.id)) { await prefetchShelfFronts() }
                    #endif
                }
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        // An episode that ended with nothing after it comes back here.
        .onReceive(NotificationCenter.default.publisher(for: .lineupReturnToLibraryFront)) { _ in
            pushed = nil
        }
        .sheet(isPresented: $searchPresented) { searchSheet }
        #if os(tvOS)
        .fullScreenCover(item: $heroPlayableItem) { item in MediaSourcePicker(item: item) }
        #else
        .sheet(item: $heroPlayableItem) { item in MediaSourcePicker(item: item) }
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
        .task { await rotateLibraryPreview() }
        .onAppear {
            tvPreview.setInitial(defaultPreviewItem)
        }
        .onChange(of: media.profiles.map(\.id)) { _, _ in tvPreview.reset(to: defaultPreviewItem) }
        #endif
    }

    /// One of the phone's rows: the device's own, or a shelf.
    private enum PhoneRow: Identifiable {
        case local(id: String, title: String, items: [MediaItem], opensPages: Bool)
        case catalog(MediaCatalog)

        var id: String {
            switch self {
            case .local(let id, _, _, _): id
            case .catalog(let catalog): catalog.id
            }
        }
    }

    /// Every row, in the order the viewer arranged them.
    private var phoneRows: [PhoneRow] {
        var rows: [PhoneRow] = []
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
                .contextMenu {
                    Button("Remove Shelf", systemImage: "minus.rectangle", role: .destructive) {
                        media.removeShelf(catalog)
                    }
                    .lineupFlatButton()
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

    /// Every shelf's first screenful, fetched as the shelves arrive, so
    /// scrolling down the Library finds posters already made rather than
    /// starting each one as its row appears.
    private func prefetchShelfFronts() async {
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        var rows: [[MediaItem]] = [continueWatching.map(\.item), favoriteTitles, favoriteEpisodes]
        rows += catalogs.map(\.items)
        for items in rows where !items.isEmpty {
            let shape = MediaArtShape.forItems(items)
            for item in items.prefix(6) {
                let art = MediaItemCard.art(for: item, shape: shape, in: media)
                LineupArt.prefetch(art.url, pixels: art.pixels)
            }
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
        while !Task.isCancelled {
            let candidates = heroItems
            guard !candidates.isEmpty else {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                continue
            }
            let nextIndex = (heroIndex + 1) % candidates.count
            let next = candidates[nextIndex]
            // Spend the eight-second dwell preloading the next frame. On a
            // normal connection the transition therefore begins with decoded
            // artwork already in memory, without making the interval longer.
            Task { await preloadBackdrop(for: next) }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            // Held still while the remote is on a card, which owns the
            // preview, or on the hero's Play, which is about to be pressed.
            guard !tvPreview.isNavigating, tvFocus != .hero, !Task.isCancelled else { continue }
            // A weak connection may miss this particular turn, but the hero
            // never rotates to a blank frame. The already-running shared load
            // keeps going and the next eight-second tick can use it.
            guard backdropIsReady(for: next) else { continue }
            showHero(at: nextIndex)
        }
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
        let rowShape: MediaArtShape = shelves.contains { MediaArtShape.forItems($0.items) == .poster } ? .poster : .still
        let blockHeight = tvShelfBlockHeight(for: rowShape)
        let heroHeight: CGFloat = heroItems.isEmpty ? 0 : 84
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                // Each row is a focus region the full width of the screen.
                // Play and the first cards sit at the left, nowhere under the
                // Library button at the right, so without that a press down
                // from the button found nothing below it and went nowhere.
                if !heroItems.isEmpty {
                    heroRow
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: heroHeight, alignment: .top)
                        .lineupFocusRegion()
                }
                if !shelves.isEmpty {
                    shelfBlock(shelves[index], index: index, count: shelves.count)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { shelfAboveStrip(shown: index > 0) }
                        .frame(height: blockHeight, alignment: .bottom)
                        .lineupFocusRegion()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .disabled(menuOpen)
            // At the top right of the artwork, clear of the title told on
            // the left, and wholly below the tab bar: Down from the tab bar
            // lands on it. Higher up it sat partly under the tab bar, which
            // the focus engine doesn't count as below it, and Down went on
            // past it to Play.
            if let options {
                TVLibraryMenuBar(options: options, onOpenChange: { menuOpen = $0 }).padding(.top, 156)
            }
        }
        // Behind, as a background: whatever the artwork and the words about
        // it measure, they are drawn in the screen's frame and can never
        // resize it. In the stack, a picture or a block of words taller than
        // the screen made the stack taller, and the whole screen -- shelf,
        // Play and artwork -- jumped as the remote moved between titles.
        .background { TVMediaLibraryCanvas(preview: tvPreview, bottomInset: blockHeight + heroHeight) }
        .ignoresSafeArea()
        .onChange(of: tvFocus) { previous, place in
            if place == .shelfAbove { cameUpFromRow(previous) } else { tvFocusChanged(to: place) }
        }
        .onChange(of: shelves.count) { _, count in
            if shelfIndex >= count { shelfIndex = max(0, count - 1) }
        }
        .task(id: TVShelfPrefetchKey(index: index, count: shelves.count)) {
            await prefetchShelves(around: index)
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
        // The panel's room above its header, and the hairline under it.
        let panel = Self.tvPanelTop + 1 + 14
        return panel + heading + 16 + art + caption + 18
    }

    /// The hero's own control: Play, and left or right for the title before
    /// or after it.
    private var heroRow: some View {
        let item = heroItem
        let focused = tvFocus == .hero
        let count = heroItems.count
        return HStack(spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                Text(item?.isSeries == true ? "Play Show" : "Play Movie")
            }
            .font(.inter(20, .semibold))
            .foregroundStyle(focused ? LineupStyle.background : LineupStyle.text)
            .padding(.horizontal, 30).frame(height: 58)
            .background(focused ? LineupStyle.text : LineupStyle.text.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(LineupStyle.text.opacity(focused ? 0 : 0.28), lineWidth: 1))
            .scaleEffect(focused ? LineupStyle.controlLift : 1)
            .lineupShadow(.lifted, on: focused)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
            .focusable()
            .focused($tvFocus, equals: .hero)
            .focusEffectDisabled()
            .onTapGesture { playHero() }
            .onMoveCommand { moveTV($0, from: .hero) }
            .contextMenu {
                if let item, item.opensPage {
                    Button("Details", systemImage: "info.circle") { pushed = item }
                        .lineupFlatButton()
                }
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
        .padding(.leading, 72)
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
            // The panel's hairline under its header.
            Rectangle().fill(LineupStyle.line).frame(height: 1)
                .padding(.horizontal, horizontalPadding)
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
        .padding(.top, Self.tvPanelTop)
        .padding(.bottom, 18)
        // The shelf sits in a panel over the artwork, as the phone's do: the
        // panels' fill and corners, held in from the screen's edges. Drawn
        // behind, so it moves nothing the focus engine has measured.
        .background {
            RoundedRectangle(cornerRadius: LineupPanelStyle.radius, style: .continuous)
                .fill(LineupPanelStyle.fill.opacity(0.94))
                .padding(.horizontal, Self.tvPanelSide)
                .padding(.bottom, 10)
        }
    }

    /// Above the header, inside the panel.
    private static let tvPanelTop: CGFloat = 24
    /// The panel's edge from the screen's: the shelf's own inset, less the
    /// panel's inner margin.
    private static let tvPanelSide: CGFloat = 26

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
            .onTapGesture { activate(item, in: shelf) }
            .onMoveCommand { moveTV($0, from: .card(slot)) }
            .scaleEffect(focused ? LineupStyle.cardLift : 1)
            .zIndex(focused ? 10 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
            .contextMenu { MediaCardActions(item: item) }
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
        .onTapGesture { pushed = catalog.root }
        .onMoveCommand { moveTV($0, from: .card(slot)) }
        .scaleEffect(focused ? LineupStyle.cardLift : 1)
        .zIndex(focused ? 10 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
        .contextMenu {
            Button("Remove Shelf", systemImage: "minus.rectangle", role: .destructive) {
                media.removeShelf(catalog)
            }
            .lineupFlatButton()
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
        withAnimation(.easeInOut(duration: 0.45)) {
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
        guard let item = heroItem else { return }
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

    private func preloadBackdrop(for item: MediaItem) async {
        guard let art = backdropArt(for: item) else { return }
        _ = await LineupArt.load(art.url, pixels: art.pixels)
    }

    private func backdropIsReady(for item: MediaItem) -> Bool {
        guard let art = backdropArt(for: item) else { return true }
        return LineupArt.ready(art.url, pixels: art.pixels) != nil
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
                                .contextMenu { continueWatchingAction(for: trackedItem) }
                                #else
                                NavigationLink(value: page) {
                                    MediaItemCard(item: trackedItem, shape: shape)
                                }
                                .lineupFlatButton()
                                .contextMenu { continueWatchingAction(for: trackedItem) }
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

    private func continueWatchingAction(for item: MediaItem) -> some View {
        MediaCardActions(item: item)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { searchPresented = false }
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
        8
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

/// A run of cards in a grid with a heading of its own: one server's search
/// results. A section with no title is just the grid.
private struct MediaGridSection: Identifiable {
    let id: String
    let title: String?
    /// The logo of the server the section is named for.
    var brand: MediaServerBrand? = nil
    let items: [MediaItem]
}

private struct MediaGridScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let title: String
    let sections: [MediaGridSection]
    // tvOS pushes by hand because its cards are not NavigationLinks any more.
    @State private var pushed: MediaItem?
    @State private var choosingShelf = false
    @State private var editingQuery = false

    init(title: String, items: [MediaItem]) {
        self.title = title
        sections = [MediaGridSection(id: "all", title: nil, items: items)]
    }

    init(title: String, sections: [MediaGridSection]) {
        self.title = title
        self.sections = sections
    }

    private var items: [MediaItem] { sections.flatMap(\.items) }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 16) {
                        if let heading = section.title {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                if let brand = section.brand {
                                    MediaServerLogo(brand: brand)
                                        .frame(width: sectionLogoSize, height: sectionLogoSize)
                                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                                }
                                Text(heading).font(headingFont)
                                Text(section.items.count == 1 ? "1 result" : "\(section.items.count) results")
                                    .font(.inter(13, .semibold))
                                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                            }
                        }
                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(section.items, id: \.libraryKey) { item in
                                cell(item)
                            }
                        }
                        // Down from a section's last row reaches the next one.
                        .lineupFocusRegion()
                    }
                }
            }
            .padding(.horizontal, horizontalPadding).padding(.vertical, 28)
        }
        .lineupFocusRegion()
    }

    @ViewBuilder
    private func cell(_ item: MediaItem) -> some View {
        if item.opensPage {
            #if os(tvOS)
            TVSelectable(drawsFocusChrome: false, action: { pushed = item }) {
                MediaItemCard(item: item, shape: shape)
            }
            #else
            NavigationLink(value: item) { MediaItemCard(item: item, shape: shape) }
                .lineupFlatButton()
            #endif
        } else {
            MediaPlayableCard(item: item, shape: shape)
        }
    }

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        grid.navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
            .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        #else
        grid.navigationTitle(title)
            .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
        #endif
    }

    private var shape: MediaArtShape { .forItems(items) }

    private var columns: [GridItem] {
        #if os(tvOS)
        shape == .poster
            ? [GridItem(.adaptive(minimum: 250, maximum: 310), spacing: 24)]
            : [GridItem(.adaptive(minimum: 360, maximum: 460), spacing: 24)]
        #else
        shape == .poster
            ? [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 14)]
            : [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 14)]
        #endif
    }
    private var gridSpacing: CGFloat {
        #if os(tvOS)
        30
        #else
        20
        #endif
    }
    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        44
        #else
        28
        #endif
    }
    private var headingFont: Font {
        #if os(tvOS)
        .inter(24, .semibold)
        #else
        .inter(.title3, .bold)
        #endif
    }
    /// A server's logo beside its section's heading, the heading's height.
    private var sectionLogoSize: CGFloat {
        #if os(tvOS)
        24
        #else
        18
        #endif
    }
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        70
        #else
        LineupPanelStyle.inset
        #endif
    }
}

/// A series or a film opens to its own page; anything else is still a grid of
/// what is inside it. All of it is registered under one item type, so the
/// choice has to be made here rather than at the link.
struct MediaBrowseDestination: View {
    let item: MediaItem

    var body: some View {
        // Anything that plays has a page when it is opened on purpose -- a
        // server's "Video" from Continue Watching as much as a "Movie".
        if let service = StreamingService.service(for: item) {
            StreamingServiceScreen(service: service)
        } else if item.id == StreamingService.rowID {
            StreamingServicesScreen()
        } else if LibraryTrendingRow.row(id: item.id) != nil {
            TrendingRowScreen(id: item.id, title: item.name)
        } else if item.hasDetailPage || item.isPlayable {
            MediaDetailScreen(item: item)
        } else {
            MediaFolderScreen(folder: item)
        }
    }
}

/// A trending row's See All: every title it holds, in the chart's order.
private struct TrendingRowScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let id: String
    let title: String

    var body: some View {
        let items = media.trendingShelves.first { $0.id == id }?.items ?? []
        if items.isEmpty {
            ContentUnavailableView("Nothing to Play Yet", systemImage: "chart.line.uptrend.xyaxis",
                description: Text("None of what is trending right now is on your servers or your IPTV provider."))
                .mediaFocusAnchor()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LineupStyle.background.ignoresSafeArea())
        } else {
            MediaGridScreen(title: title, items: items)
                .background(LineupStyle.background.ignoresSafeArea())
        }
    }
}

private struct MediaFolderScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let folder: MediaItem
    @State private var items: [MediaItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading \(folder.name)…").mediaFocusAnchor()
            } else if let error {
                ContentUnavailableView("Couldn’t Load Library", systemImage: "exclamationmark.triangle",
                    description: Text(error)).mediaFocusAnchor()
            } else if items.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "film.stack",
                    description: Text("This library did not return any playable items.")).mediaFocusAnchor()
            } else {
                MediaGridScreen(title: folder.name, items: items)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .task(id: folder.libraryKey) {
            loading = true
            do { items = try await media.items(in: folder); error = nil }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

/// On iPhone the hero art runs to the very top of the screen, under a
/// navigation bar carrying no background of its own.
///
/// tvOS gets neither half. Its tab bar sits along the *top* edge and appears
/// when focus moves up into it, so a screen that ignores the top safe area
/// draws over that bar and takes the focus meant for it -- leaving the Menu
/// button with nowhere to go and the viewer stuck on the page. Every other tvOS
/// screen here ignores `[.horizontal, .bottom]` and leaves the top alone for
/// exactly this reason.
private struct FullBleedHeader: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .ignoresSafeArea(edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }
}

/// Which shelves to show, in two groups: the server's own libraries, and the
/// collections -- which on a Nullfin server is where an enabled catalog
/// lands, one collection per catalog.
///
/// Lineup only ever asked `/views` for this list, and that route answers with
/// promoted collections alone. An imported catalog is left unpromoted, so no
/// number of them could put one in front of the viewer. The second
/// group is the part that was missing.
private struct MediaShelfPicker: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var adding: Set<String> = []

    private struct Group: Identifiable {
        let id: String
        let title: String
        let detail: String
        /// The logo of the server the group is named for.
        var brand: MediaServerBrand? = nil
        let items: [MediaItem]
    }

    private struct MDBListGroup: Identifiable {
        let section: MDBListCatalogSection
        let items: [MDBListCatalog]
        var id: MDBListCatalogSection { section }
    }

    /// Each server's libraries and catalogs, server by server. With more than
    /// one, every heading says whose they are.
    private var groups: [Group] {
        let several = media.profiles.count > 1
        let servers = media.profiles.flatMap { server -> [Group] in
            let owner = several ? " · " + server.name.uppercased() : ""
            let brand = several ? MediaServerBrand.of(server) : nil
            return [Group(id: server.id.uuidString + "|libraries", title: "LIBRARIES" + owner,
                          detail: several ? "Folders \(server.name) keeps itself" : "Folders this server keeps itself",
                          brand: brand, items: media.availableLibraries(on: server)),
                    Group(id: server.id.uuidString + "|catalogs", title: "IMPORTED CATALOGS" + owner,
                          detail: several ? "Already on \(server.name), ready to shelve" : "Already on your server, ready to shelve",
                          brand: brand, items: media.availableCatalogs(on: server))]
        }
        // The IPTV provider's own categories, films and then shows.
        var provider: [Group] = []
        if let name = media.providerVOD.profile?.name {
            let shelves = media.availableProviderShelves
            provider = [Group(id: "provider|films", title: "MOVIES · " + name.uppercased(),
                              detail: "Film categories from your IPTV provider", items: shelves.films),
                        Group(id: "provider|shows", title: "SERIES · " + name.uppercased(),
                              detail: "Series categories from your IPTV provider", items: shelves.shows)]
        }
        return (servers + provider).filter { !$0.items.isEmpty }
    }

    private var mdbListGroups: [MDBListGroup] {
        MDBListCatalogSection.allCases.compactMap { section in
            let items = media.availableMDBListCatalogs.filter { $0.section == section }
            return items.isEmpty ? nil : MDBListGroup(section: section, items: items)
        }
    }

    private var hasAnything: Bool {
        !media.hiddenBuiltInRows.isEmpty || !groups.isEmpty || !media.addonGroups.isEmpty
            || !media.availableMDBListCatalogs.isEmpty
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ADD A SHELF").modifier(LineupGroupHeading())
                Text("Pick a row for the Library tab")
                    .font(.inter(22, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 18)
            list
        }
        .frame(maxWidth: 1180, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        .onExitCommand { dismiss() }
        .task { await loadSources() }
        #else
        NavigationStack {
            list
                .navigationTitle("Add Shelf")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: dismiss.callAsFunction)
                    }
                }
        }
        .task { await loadSources() }
        #endif
    }

    @ViewBuilder
    private var list: some View {
        if !hasAnything {
            ContentUnavailableView("Every Shelf Is Showing", systemImage: "rectangle.stack.badge.plus",
                description: Text(emptyDetail))
                .mediaFocusAnchor()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // The Library's own row, back once it was taken away.
                    if !media.hiddenBuiltInRows.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("BUILT IN").modifier(LineupGroupHeading())
                            Text("Rows Lineup puts together for you").font(.inter(13))
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(media.hiddenBuiltInRows) { row in
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift, fillRadius: 14,
                                         action: { media.setShowsBuiltInRow(row.id, true) }) {
                                MediaShelfRow(title: row.title, detail: row.detail, busy: false)
                            }
                            #else
                            Button { media.setShowsBuiltInRow(row.id, true) } label: {
                                MediaShelfRow(title: row.title, detail: row.detail, busy: false)
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                if let brand = group.brand {
                                    MediaServerLogo(brand: brand).frame(width: 14, height: 14)
                                }
                                Text(group.title).modifier(LineupGroupHeading())
                            }
                            Text(group.detail).font(.inter(13))
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(group.items, id: \.libraryKey) { item in
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift,
                                fillRadius: 14, action: { add(item) }) {
                                MediaShelfRow(title: item.name, detail: countText(item),
                                    busy: adding.contains(item.libraryKey))
                            }
                            #else
                            Button { add(item) } label: {
                                MediaShelfRow(title: item.name, detail: countText(item),
                                    busy: adding.contains(item.libraryKey))
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                    ForEach(mdbListGroups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.section.title).modifier(LineupGroupHeading())
                            Text(group.section.detail + " — playable titles found on "
                                 + (media.profiles.count > 1 ? "your media servers" : "this media server"))
                                .font(.inter(13))
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(group.items) { catalog in
                            let busy = adding.contains(catalog.shelfID)
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift,
                                fillRadius: 14, action: { addMDBList(catalog) }) {
                                MediaShelfRow(title: catalog.name,
                                    detail: catalog.itemCount.map { "\($0) list titles" }, busy: busy)
                            }
                            #else
                            Button { addMDBList(catalog) } label: {
                                MediaShelfRow(title: catalog.name,
                                    detail: catalog.itemCount.map { "\($0) list titles" }, busy: busy)
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                    // Catalogs the server offers that it is not importing yet.
                    // Choosing one switches it on and asks the server to fetch
                    // it, which it then does in its own time.
                    ForEach(media.addonGroups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                if media.serverName(of: group.serverID) != nil,
                                   let brand = media.serverBrand(of: group.serverID) {
                                    MediaServerLogo(brand: brand).frame(width: 14, height: 14)
                                }
                                Text(addonHeading(group))
                                    .modifier(LineupGroupHeading())
                            }
                            // The server re-imports every enabled catalog when
                            // asked, so this is minutes, not seconds. Saying so
                            // is the difference between waiting and giving up.
                            Text(media.importing.isEmpty
                                ? "Not imported yet — choosing one starts the import"
                                : "Importing can take several minutes. You can close this; it keeps going.")
                                .font(.inter(13))
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(group.catalogs) { catalog in
                            let busy = media.isImporting(catalog, in: group)
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift, fillRadius: 14,
                                action: { enable(catalog, in: group) }) {
                                MediaShelfRow(title: catalog.name,
                                    detail: busy ? "Importing… select again to stop waiting" : nil,
                                    busy: busy)
                            }
                            #else
                            Button { enable(catalog, in: group) } label: {
                                MediaShelfRow(title: catalog.name,
                                    detail: busy ? "Importing… tap again to stop waiting" : nil,
                                    busy: busy)
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                }
                .padding(.horizontal, rowPadding).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .lineupFocusRegion()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LineupStyle.background.ignoresSafeArea())
            .foregroundStyle(LineupStyle.lightPurple)
        }
    }

    /// The picker stays up: a row leaves the list as its shelf appears behind,
    /// so several can be added without reopening this each time.
    private func add(_ item: MediaItem) {
        guard !adding.contains(item.libraryKey) else { return }
        adding.insert(item.libraryKey)
        Task { @MainActor in
            await media.addShelf(item)
            adding.remove(item.libraryKey)
        }
    }

    private func addMDBList(_ catalog: MDBListCatalog) {
        guard !adding.contains(catalog.shelfID) else { return }
        adding.insert(catalog.shelfID)
        Task { @MainActor in
            await media.addMDBListShelf(catalog)
            adding.remove(catalog.shelfID)
        }
    }

    private func loadSources() async {
        async let addons: Void = media.loadAddonCatalogs()
        async let mdbList: Void = media.loadMDBListIntegration()
        async let provider: Void = media.loadProviderCatalog()
        _ = await (addons, mdbList, provider)
    }

    /// Switching a catalog on is the server's work, not this screen's: it can
    /// run for minutes, so it is left with the library and the row simply
    /// reports it. Closing this screen does not cancel it.
    ///
    /// Pressing a row that is already working calls the waiting off, so nobody
    /// is held by a spinner they cannot get out of. The server carries on.
    private func enable(_ catalog: NullfinCatalog, in group: MediaLibrary.AddonCatalogGroup) {
        if media.isImporting(catalog, in: group) {
            media.stopWaiting(for: catalog, in: group)
        } else {
            media.enableCatalog(catalog, in: group)
        }
    }

    /// An addon's name, and its server's when there is more than one.
    private func addonHeading(_ group: MediaLibrary.AddonCatalogGroup) -> String {
        (media.serverName(of: group.serverID).map { group.name + " · " + $0 } ?? group.name).uppercased()
    }

    private var emptyDetail: String {
        let several = media.profiles.count > 1
        if media.addonsUnavailable {
            return several
                ? "Your servers offer no other library or catalog, and they do not let these accounts browse their catalogs -- sign in as an administrator to switch them on from here."
                : "This server offers no other library or catalog, and it does not let this account browse its catalogs -- sign in as an administrator to switch them on from here."
        }
        return several
            ? "Your servers offer no other library or catalog."
            : "This server offers no other library or catalog."
    }

    private func countText(_ item: MediaItem) -> String? {
        guard let count = item.childCount, count > 0 else { return nil }
        return "\(count) titles"
    }

    private var rowPadding: CGFloat {
        #if os(tvOS)
        28
        #else
        16
        #endif
    }
}

private struct MediaShelfRow: View {
    let title: String
    var detail: String?
    let busy: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.inter(nameSize, .semibold))
                    .lineLimit(2).multilineTextAlignment(.leading)
                if let detail {
                    Text(detail).font(.inter(detailSize))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                }
            }
            Spacer(minLength: 16)
            if busy {
                ProgressView()
            } else {
                Image(systemName: "plus.circle")
                    .font(.inter(nameSize, .semibold))
                    .foregroundStyle(LineupStyle.highlight)
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .background(LineupStyle.surface.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #else
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add " + title)
    }

    #if os(tvOS)
    private var nameSize: CGFloat { 22 }
    private var detailSize: CGFloat { 14 }
    #else
    private var nameSize: CGFloat { 17 }
    private var detailSize: CGFloat { 13 }
    #endif
}

/// The page a series or a film opens to: its art, what it is, and what to play
/// -- for a series, the episode the viewer is up to, with every episode of that
/// season under it; for a film, the film.
///
/// A film used to go from its poster straight to a list of streams, which
/// skipped the part where somebody decides whether to watch it: no
/// description, no year, no running time, no rating. It gets this page too now,
/// minus the parts a film has no answer for.
private struct MediaDetailScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let item: MediaItem

    @State private var detail: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var selectedSeason: MediaItem?
    @State private var episodes: [MediaItem] = []
    @State private var nextUp: MediaItem?
    @State private var related: [MediaItem] = []
    @State private var pageReady = false
    #if os(tvOS)
    @State private var preparedHero: UIImage?
    #endif
    @State private var favorite = false
    @State private var watched = false
    @State private var expandedOverview = false
    @State private var loading = true
    @State private var error: String?
    @State private var chosen: MediaItem?
    /// Set by Start Over, so the stream that opens ignores the saved place.
    @State private var startingOver = false
    // tvOS media cards push through state instead of NavigationLink. Besides
    // avoiding the system's oversized focus plate, this lets the Related row
    // participate in the same focus-region routing as every library shelf.
    @State private var pushed: MediaItem?
    @FocusState private var seasonFocused: Bool
    #if os(tvOS)
    @FocusState private var backFocused: Bool
    @Environment(\.tvTabBar) private var tabBar
    #endif
    @State private var choosingSeason = false
    #if !os(tvOS)
    /// The seasons, dropped from the Seasons button under the episodes'
    /// header.
    @State private var seasonMenuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// IMDb, TMDB and Rotten Tomatoes, once found. The television draws its
    /// page through the hero's own view, which finds them itself.
    @State private var pageRatings: MediaRatings?
    #endif

    private var subject: MediaItem { detail ?? item }

    var body: some View {
        Group {
            #if os(tvOS)
            if pageReady {
                detailContent
            } else {
                ProgressView("Loading \(item.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mediaFocusAnchor()
            }
            #else
            detailContent
            #endif
        }
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        #if !os(tvOS)
        .overlayPreferenceValue(MediaSeasonMenuAnchor.self) { anchor in
            GeometryReader { proxy in
                if seasonMenuOpen, let anchor {
                    seasonDropdown(from: proxy[anchor], in: proxy.size)
                }
            }
            .allowsHitTesting(seasonMenuOpen)
        }
        #endif
        .modifier(FullBleedHeader())
        .task(id: item.libraryKey) { await load() }
        #if !os(tvOS)
        .task(id: item.libraryKey) { pageRatings = await media.ratings(for: item) }
        #endif
        #if os(tvOS)
        // Full-screen artwork: the tab bar goes while the page is up.
        .onAppear { tabBar?.pageAppeared() }
        .onDisappear { tabBar?.pageDisappeared() }
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $chosen) { episode in MediaSourcePicker(item: episode, startsOver: startingOver) }
        #else
        .sheet(item: $chosen) { episode in MediaSourcePicker(item: episode) }
        #endif
    }

    private var detailContent: some View {
        #if os(tvOS)
        tvDetailContent
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                VStack(alignment: .leading, spacing: 16) {
                    Text(subject.name).font(titleFont)
                    if let ratings = pageRatings ?? media.knownRatings(for: subject), !ratings.isEmpty {
                        MediaRatingChips(ratings: ratings)
                    }
                    metaLine
                    actions
                    overview
                }
                .padding(.horizontal, horizontalPadding)
                // Up into the fade. The art running down the screen and the
                // title sitting on the last of it is one picture; the title
                // waiting below a finished band of artwork is two.
                .padding(.top, contentRise)
                episodesSection
                trailersSection
                castSection
                relatedSection
            }
            .padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    #if os(tvOS)
    /// Selection keeps the same backdrop and information hierarchy as Library
    /// focus, then adds actions and playable rows without dropping into a
    /// separate card-shaped page.
    private var tvDetailContent: some View {
        ZStack(alignment: .top) {
            TVMediaCinematicBackdrop(item: subject)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Room for the ratings above the year and genres.
                    TVMediaLibraryPreview(item: subject)
                        .frame(height: 460)
                        .allowsHitTesting(false)
                    tvActions.padding(.horizontal, horizontalPadding)
                    episodesSection
                    trailersSection
                    relatedSection
                }
                .padding(.bottom, 60)
            }
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private var tvActions: some View {
        HStack(spacing: 16) {
            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                         action: { startingOver = false; chosen = playTarget },
                         requestInitialFocus: true) {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                    Text(playTarget.flatMap { media.resumePosition(for: $0) } == nil ? "Play" : "Resume")
                    if let code = playTarget?.episodeCode {
                        Text(code).opacity(0.62)
                    }
                }
                .font(.inter(18, .semibold))
                .padding(.horizontal, 26).frame(height: 54)
                .modifier(TVMediaActionSurface())
            }
            .disabled(playTarget == nil)
            .opacity(playTarget == nil ? 0.45 : 1)

            // Resume picks up where the viewer left off; this is the way back
            // to the opening scene, which otherwise meant scrubbing for it.
            if playTarget.flatMap({ media.resumePosition(for: $0) }) != nil {
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                             action: { startingOver = true; chosen = playTarget }) {
                    tvSecondaryAction("Start Over", symbol: "backward.end.fill")
                }
            }

            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                favorite.toggle()
                media.setLocalFavorite(favorite, for: subject)
                Task { await media.setFavorite(favorite, for: subject) }
            }) {
                tvSecondaryAction(favorite ? "In Favorites" : "Add to Favorites",
                                  symbol: favorite ? "heart.fill" : "heart")
            }

            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                watched.toggle()
                media.setLocallyPlayed(watched, for: subject)
                Task { await media.setPlayed(watched, for: subject) }
            }) {
                tvSecondaryAction(watched ? "Watched" : "Mark Watched",
                                  symbol: watched ? "eye.fill" : "eye")
            }
        }
        .lineupFocusRegion()
    }

    private func tvSecondaryAction(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.inter(17, .semibold))
            .padding(.horizontal, 20).frame(height: 52)
            .modifier(TVMediaActionSurface())
    }
    #endif

    // MARK: - Header

    private var hero: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(heroRatio, contentMode: .fit)
            // Top, not centre. A backdrop is 16:9 and this box is wider than
            // that, so filling it crops the difference -- and centred, half of
            // that crop came off the top, which is where the faces are. Anchored
            // here the whole crop falls at the foot of the art, under the fade
            // that is already taking it into the page.
            .overlay {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    #if os(tvOS)
                    if let preparedHero {
                        Image(uiImage: preparedHero).resizable().scaledToFill()
                    }
                    #else
                    LineupArtView(url: heroURL, width: heroWidth) { loaded in
                        if let image = loaded { image.resizable().scaledToFill() }
                        // The gradient behind is the placeholder, so there is
                        // nothing to draw here -- but something has to be
                        // returned. A closure that can produce no view at all
                        // is what left this blank once already.
                        else { Color.clear }
                    }
                    #endif
                }
            }
            .clipped()
            // The art has to end somewhere, and a hard edge across the screen
            // reads as a seam. It fades into the page instead -- over a long
            // way, and through a middle stop, because a two-stop fade over a
            // short distance is a visible band rather than a disappearance.
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: LineupStyle.background.opacity(0.62), location: 0.46),
                    .init(color: LineupStyle.background, location: 0.9)
                ], startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
            }
            #if os(tvOS)
            // Focus needs a home at the top of the scroll view. Otherwise
            // tvOS chooses Play below the hero and scrolls the whole page on
            // entry, dragging the navigation/tab chrome off the screen.
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .frame(width: 56, height: 56)
                        .background(LineupStyle.background.opacity(0.72), in: Circle())
                }
                .lineupFlatButton()
                .focused($backFocused)
                .padding(.leading, horizontalPadding).padding(.top, 24)
                .onAppear { backFocused = true }
            }
            #endif
    }

    @ViewBuilder
    private var metaLine: some View {
        if !metaParts.isEmpty {
            Text(metaParts.joined(separator: "  \u{00B7}  "))
                .font(.inter(.subheadline, .medium))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
        }
    }

    private var metaParts: [String] {
        [subject.productionYear.map(String.init),
         // Worth saying on a film, where a server reports one; a series has no
         // single running time and leaves this out.
         subject.formattedRuntime,
         subject.genres?.prefix(2).joined(separator: ", "),
         subject.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    // MARK: - Actions

    /// What the play button starts: for a film, the film. For a series, the
    /// server's own next-up answer, else the first unwatched episode on
    /// screen, else the season from the top.
    private var playTarget: MediaItem? {
        guard subject.isSeries else { return subject }
        return nextUp ?? episodes.first { !media.isWatched($0) } ?? episodes.first
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { chosen = playTarget } label: { playLabel.modifier(MediaChromeFocus()) }
            .lineupFlatButton()
            .disabled(playTarget == nil)
            .opacity(playTarget == nil ? 0.45 : 1)

            // Keep the Library useful even when a server cannot write user
            // state, while still mirroring the choice back when it can.
            Group {
                iconButton(favorite ? "heart.fill" : "heart") {
                    favorite.toggle()
                    media.setLocalFavorite(favorite, for: subject)
                    Task { await media.setFavorite(favorite, for: subject) }
                }
                iconButton(watched ? "eye.fill" : "eye") {
                    watched.toggle()
                    media.setLocallyPlayed(watched, for: subject)
                    Task { await media.setPlayed(watched, for: subject) }
                }
            }
            // Nothing to shuffle through on a film.
            if subject.isSeries {
                iconButton("shuffle") { chosen = episodes.randomElement() ?? playTarget }
                    .disabled(episodes.isEmpty)
            }
        }
        .lineupFocusRegion()
    }

    /// The play button.
    ///
    /// The same surface as the heart, the eye and the shuffle beside it. It
    /// used to be filled on the phone, on the theory that a primary action
    /// should be the one thing a thumb goes for -- but the fill is a pale slab
    /// against a dark page, sitting directly beside three dark controls, and
    /// what it read as was a mistake rather than an emphasis. The television
    /// had already dropped it for the same reason.
    ///
    /// It is still the widest thing in the row, which is how it says it is the
    /// main one. Width is the emphasis now; brightness was too much of it.
    @ViewBuilder
    private var playLabel: some View {
        let text = HStack(spacing: 8) {
            Image(systemName: "play.fill")
            Text(playTarget.flatMap { media.resumePosition(for: $0) } == nil ? "Play" : "Resume")
                .font(.inter(17, .semibold))
            if let code = playTarget?.episodeCode {
                // Quieter than the word beside it, on the same dark surface
                // both platforms now use.
                Text(code).foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
            }
        }
        .font(.inter(17))
        #if os(tvOS)
        text.padding(.horizontal, 22).frame(height: buttonHeight)
        #else
        text.frame(maxWidth: .infinity).frame(height: buttonHeight)
        #endif
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        let label = Image(systemName: symbol).font(.system(size: 17, weight: .semibold, design: .rounded))
            .frame(width: buttonHeight + 8, height: buttonHeight)
            .modifier(MediaChromeFocus())
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, action: action) { label }
        #else
        Button(action: action) { label }.lineupFlatButton()
        #endif
    }

    @ViewBuilder
    private var overview: some View {
        if let text = subject.overview, !text.isEmpty {
            Text(text)
                .font(.inter(.subheadline))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.76))
                .lineLimit(expandedOverview ? nil : 3)
                .multilineTextAlignment(.leading)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { expandedOverview.toggle() }
                }
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodesSection: some View {
        // A film has none, and an empty section would still cost the spacing
        // above it.
        if subject.isSeries {
            episodeList
        }
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(tvOS)
            seasonHeading.padding(.horizontal, horizontalPadding).lineupFocusRegion()
            #else
            PhoneShelfHeader(title: selectedSeason?.name ?? "Episodes", symbol: "list.number") {
                if seasons.count > 1 {
                    Button { setSeasonMenu(!seasonMenuOpen) } label: {
                        HStack(spacing: 3) {
                            Text("Seasons")
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .heavy, design: .rounded))
                                .rotationEffect(.degrees(seasonMenuOpen ? -180 : 0))
                        }
                        .font(.inter(14, .bold))
                        .foregroundStyle(LineupStyle.highlight)
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .anchorPreference(key: MediaSeasonMenuAnchor.self, value: .bounds) { $0 }
                    .accessibilityLabel("Seasons")
                    .accessibilityHint(seasonMenuOpen ? "Closes the list of seasons" : "Shows the list of seasons")
                }
            }
            #endif
            if loading {
                // Play and shuffle are both disabled until an episode is known,
                // so until then this page has nothing focusable on it at all.
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    .mediaFocusAnchor()
            } else if let error {
                Text(error).font(.inter(.footnote))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    .padding(.horizontal, horizontalPadding)
                    .mediaFocusAnchor()
            } else if episodes.isEmpty {
                Text("No episodes here yet.").font(.inter(.footnote))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    .padding(.horizontal, horizontalPadding)
                    .mediaFocusAnchor()
            } else {
                #if os(tvOS)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) {
                        ForEach(episodes) { episode in
                            TVSelectable(drawsFocusChrome: false, action: { chosen = episode }) {
                                MediaEpisodeCard(episode: episode)
                            }
                            .frame(width: 420, alignment: .topLeading)
                            .contextMenu { episodeLibraryActions(episode) }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                .lineupFocusRegion()
                #else
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(episodes) { episode in
                            Button { chosen = episode } label: { MediaEpisodeCard(episode: episode) }
                                .lineupFlatButton()
                                .frame(width: 265)
                                .contextMenu { episodeLibraryActions(episode) }
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                #endif
            }
        }
        .modifier(PhoneShelfPanel(bottom: 18))
    }

    // MARK: - More about this title

    @ViewBuilder
    private var trailersSection: some View {
        let trailers = (subject.remoteTrailers ?? []).compactMap { trailer -> (String, URL, URL?)? in
            guard let address = trailer.url, let url = URL(string: address),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (trailer.name ?? "Trailer", url, trailer.thumbnailURL)
        }
        if !trailers.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                detailSectionTitle("Trailers", symbol: "play.rectangle")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(trailers.indices, id: \.self) { index in
                            #if os(tvOS)
                            TVSelectable(action: { openURL(trailers[index].1) }) {
                                trailerCard(title: trailers[index].0, thumbnail: trailers[index].2)
                            }
                            #else
                            Link(destination: trailers[index].1) {
                                trailerCard(title: trailers[index].0, thumbnail: trailers[index].2)
                            }
                            .lineupFlatButton()
                            #endif
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
            }
            .modifier(PhoneShelfPanel(bottom: 18))
        }
    }

    private func trailerCard(title: String, thumbnail: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(LineupStyle.surface)
                LineupArtView(url: thumbnail ?? media.backdropURL(for: subject), width: 320) { loaded in
                    if let loaded { loaded.resizable().scaledToFill() }
                    else { Color.clear }
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(15)
                    .background(.black.opacity(0.58), in: Circle())
            }
            .frame(width: trailerWidth, height: trailerWidth * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title).font(.inter(.subheadline, .semibold)).lineLimit(1)
        }
        .frame(width: trailerWidth, alignment: .leading)
    }

    @ViewBuilder
    private func episodeLibraryActions(_ episode: MediaItem) -> some View {
        let watched = media.isWatched(episode)
        Button(watched ? "Remove from Watched" : "Mark Watched", systemImage: watched ? "eye.slash" : "eye.fill") {
            Task { await media.setEpisodePlayedAndAdvance(!watched, for: episode) }
        }
        .lineupFlatButton()
        let favorite = media.isLocalFavorite(episode)
        Button(favorite ? "Remove from Favorites Library" : "Add to Favorites Library", systemImage: favorite ? "heart.slash" : "heart.fill") {
            media.setLocalFavorite(!favorite, for: episode)
            Task { await media.setFavorite(!favorite, for: episode) }
        }
        .lineupFlatButton()
    }

    @ViewBuilder
    private var castSection: some View {
        let cast = (subject.people ?? []).filter { $0.type?.lowercased() == "actor" }
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                detailSectionTitle("Cast", symbol: "person.2")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(cast) { person in
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).fill(LineupStyle.surface)
                                    LineupArtView(url: media.personImageURL(for: person, of: subject), width: 112) { loaded in
                                        if let image = loaded {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "person.fill")
                                                .font(.inter(.largeTitle))
                                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.35))
                                        }
                                    }
                                }
                                .frame(width: 112, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(person.name).font(.inter(.caption, .semibold)).lineLimit(2)
                                if let role = person.role, !role.isEmpty {
                                    Text(role).font(.inter(.caption2)).lineLimit(2)
                                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                                }
                            }
                            .frame(width: 112, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
            }
            .modifier(PhoneShelfPanel(bottom: 18))
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                // Named for what it holds, because a row of posters under a
                // bare "Related" does not say whether it is offering films or
                // series.
                detailSectionTitle(subject.isSeries ? "Related Shows" : "Related Movies",
                                   symbol: "square.stack")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: relatedItemSpacing) {
                        ForEach(related, id: \.libraryKey) { title in
                            Group {
                                #if os(tvOS)
                                TVSelectable(drawsFocusChrome: false, action: { pushed = title }) {
                                    MediaItemCard(item: title, shape: .poster)
                                }
                                #else
                                NavigationLink(destination: MediaBrowseDestination(item: title)) {
                                    MediaItemCard(item: title, shape: .poster)
                                }
                                .lineupFlatButton()
                                #endif
                            }
                            .frame(width: relatedCardWidth, alignment: .topLeading)
                        }
                    }
                    // Give the focused card's lift room without changing the
                    // top edge shared by every poster in the row.
                    .padding(.vertical, 8)
                }
                .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                // After a viewer scrolls far sideways there may be no control
                // geometrically above that poster. Treating the shelf as one
                // focus region lets an Up press return to the rows above.
                .lineupFocusRegion()
            }
            .modifier(PhoneShelfPanel())
        }
    }

    /// A section's title: the television's large heading, the phone's
    /// panel header with its hairline.
    @ViewBuilder
    private func detailSectionTitle(_ title: String, symbol: String) -> some View {
        #if os(tvOS)
        TVShelfTitle(title: title, symbol: symbol)
            .padding(.horizontal, horizontalPadding)
        #else
        PhoneShelfHeader(title: title, symbol: symbol) { EmptyView() }
        #endif
    }

    private var relatedCardWidth: CGFloat {
        #if os(tvOS)
        // Match the poster shelves in MediaCatalogsScreen. The old 145-point
        // phone width made TV artwork cramped and visually uneven.
        230
        #else
        145
        #endif
    }

    private var relatedItemSpacing: CGFloat {
        #if os(tvOS)
        22
        #else
        14
        #endif
    }

    @ViewBuilder
    private var seasonHeading: some View {
        if seasons.count > 1 {
            #if os(tvOS)
            // A Menu renders through tvOS's own chrome, which is the bulk this
            // screen had left. Same treatment as Add Shelf: no Menu.
            TVSelectable(scale: LineupStyle.controlLift, action: { choosingSeason = true }) {
                HStack(spacing: 7) {
                    Text(selectedSeason?.name ?? "Episodes").font(sectionTitleFont)
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .modifier(MediaChromeSurface())
            }
            .confirmationDialog("Season", isPresented: $choosingSeason, titleVisibility: .visible) {
                ForEach(seasons) { season in
                    Button(season.name) { Task { await loadSeason(season) } }
                }
                Button("Cancel", role: .cancel) { }
            }
            #else
            Menu {
                ForEach(seasons) { season in
                    Button(season.name) { Task { await loadSeason(season) } }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(selectedSeason?.name ?? "Episodes").font(sectionTitleFont)
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .modifier(MediaChromeSurface(focused: seasonFocused))
            }
            .focused($seasonFocused)
            .focusEffectDisabled()
            #endif
        } else {
            Text(selectedSeason?.name ?? "Episodes").font(sectionTitleFont)
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        error = nil
        related = []
        pageReady = false
        #if os(tvOS)
        preparedHero = nil
        #endif
        let loaded = try? await media.details(of: item)
        detail = loaded ?? item
        favorite = (loaded ?? item).isFavorite || media.isLocalFavorite(loaded ?? item)
        watched = media.isWatched(loaded ?? item)
        let detailedItem = subject
        // While the viewer reads the page, so its VOD copies are waiting when
        // they choose to play.
        media.prepareProviderLookup(for: detailedItem)
        #if os(tvOS)
        // Build the complete first frame before focus enters the page. The
        // artwork is decoded once, rather than popping in through AsyncImage.
        async let relatedItems = media.related(to: detailedItem)
        let heroURLs = [media.backdropURL(for: detailedItem),
                        media.imageURL(for: detailedItem, width: 1280)].compactMap { $0 }
        async let heroData = Self.fetchHeroData(from: heroURLs)
        related = await relatedItems
        preparedHero = (await heroData).flatMap(UIImage.init(data:))
        #else
        related = await media.related(to: detailedItem)
        #endif
        // A film is the whole of itself: nothing underneath to go and get.
        guard subject.isSeries else { loading = false; pageReady = true; return }
        do {
            let children = try await media.numberedChildren(of: item)
            let seasonList = children.filter { $0.type == "Season" }
            guard !seasonList.isEmpty else {
                // Some imported catalogs hang episodes straight off the item.
                seasons = []
                selectedSeason = nil
                episodes = children.filter(\.isPlayable)
                loading = false
                pageReady = true
                return
            }
            seasons = seasonList
            // Where the viewer is in the show -- an episode part-watched on
            // this device, else the one after the last they finished, else
            // the server's next one -- and the season it is in, so the page
            // opens where they were, with every other episode a choice away.
            nextUp = await media.resumeEpisode(in: subject)
            await loadSeason(seasonList.first { $0.indexNumber == nextUp?.parentIndexNumber } ?? seasonList[0])
            pageReady = true
        } catch {
            self.error = error.localizedDescription
            loading = false
            pageReady = true
        }
    }

    #if !os(tvOS)
    private func setSeasonMenu(_ open: Bool) {
        guard seasonMenuOpen != open else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
            seasonMenuOpen = open
        }
    }

    /// The seasons, hung from the button that opens them: under it where
    /// there is room, above it where it sits near the foot of the screen.
    private func seasonDropdown(from button: CGRect, in size: CGSize) -> some View {
        let width = min(260, size.width - 32)
        let x = min(max(16, button.maxX - width), size.width - width - 16)
        let below = size.height - button.maxY - 24
        let above = button.minY - 24
        let opensUp = below < 200 && above > below
        let sections = [MobileMenuSection(id: "seasons", items: seasons.map { season in
            MobileMenuItem(season.name, id: "\(season.id)", isSelected: season.id == selectedSeason?.id) {
                Task { await loadSeason(season) }
            }
        })]
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { setSeasonMenu(false) }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                if opensUp { Spacer(minLength: 0) } else { Color.clear.frame(height: button.maxY + 6) }
                MobileDropdownPanel(title: "Seasons", symbol: "list.number", sections: sections,
                                    maxHeight: opensUp ? above : below) { setSeasonMenu(false) }
                    .frame(width: width)
                if opensUp { Color.clear.frame(height: size.height - button.minY + 6) } else { Spacer(minLength: 0) }
            }
            .padding(.leading, x)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .transition(.opacity)
    }
    #endif

    private func loadSeason(_ season: MediaItem) async {
        selectedSeason = season
        loading = true
        error = nil
        do { episodes = try await media.numberedChildren(of: season).filter(\.isPlayable) }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    // MARK: - Metrics

    private var heroURL: URL? {
        #if os(tvOS)
        media.backdropURL(for: subject) ?? media.imageURL(for: subject, width: 1280)
        #else
        media.imageURL(for: subject, width: 900)
        #endif
    }
    /// Wider than any iPhone, so the hero is never decoded short of the screen
    /// it fills. It is one picture on one page; the saving is not worth a
    /// measurement pass to get it exact.
    private var heroWidth: CGFloat { 460 }
    #if os(tvOS)
    nonisolated private static func fetchHeroData(from urls: [URL]) async -> Data? {
        for url in urls {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode), !data.isEmpty { return data }
        }
        return nil
    }
    #endif
    private var heroRatio: CGFloat {
        #if os(tvOS)
        // Leave the first action inside the initial focus viewport. At 20:9
        // the focused Play button was below the fold, so tvOS auto-scrolled
        // the whole page on entry and clipped the tab/navigation chrome.
        3
        #else
        2 / 3
        #endif
    }
    /// How far the page's text reaches up into the fading art. Negative: it is
    /// closing the gap the stack would otherwise leave.
    private var contentRise: CGFloat {
        #if os(tvOS)
        -110
        #else
        0
        #endif
    }
    /// How far the art is feathered into the page at its foot. A phone keeps
    /// this short: the fade used to run 160 points up a poster and take the
    /// artwork's own title into shadow with it.
    private var fadeHeight: CGFloat {
        #if os(tvOS)
        250
        #else
        80
        #endif
    }
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        70
        #else
        LineupPanelStyle.inset
        #endif
    }
    private var buttonHeight: CGFloat {
        #if os(tvOS)
        50
        #else
        50
        #endif
    }
    private var trailerWidth: CGFloat {
        #if os(tvOS)
        360
        #else
        260
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .inter(40, .heavy)
        #else
        .inter(.title, .heavy)
        #endif
    }
    private var sectionTitleFont: Font {
        #if os(tvOS)
        .inter(24, .heavy)
        #else
        .inter(.title3, .heavy)
        #endif
    }
    private var episodeColumns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 360, maximum: 460), spacing: 24)]
        #else
        [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 14)]
        #endif
    }
}

#if os(tvOS)
/// Detail actions keep their pill silhouette at all times and communicate
/// focus with a clean fill, never with a second rectangular frame around the
/// button's bounds.
private struct TVMediaActionSurface: ViewModifier {
    @Environment(\.lineupTVSelectableFocused) private var focused

    func body(content: Content) -> some View {
        content
            .foregroundStyle(LineupStyle.lightPurple)
            .background(Color.black.opacity(0.58), in: Capsule())
            .lineupFocusLayer(focused, in: Capsule())
            .lineupShadow(.lifted, on: focused)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }
}
#endif

/// An episode card says which episode it is and what happens in it, so a viewer
/// picks by the description rather than by guessing from a still.
private struct MediaEpisodeCard: View {
    @EnvironmentObject private var media: MediaLibrary
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var artworkFocused
    #endif
    let episode: MediaItem

    var body: some View {
        let playback = playbackPresentation
        return VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    ZStack {
                        LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                        LineupArtView(url: media.imageURL(for: episode, width: 640), width: 360) { loaded in
                            if let image = loaded { image.resizable().scaledToFill() }
                            else { Image(systemName: "film.fill").font(.inter(.largeTitle)) }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let playback {
                            MediaArtworkProgress(playback: playback)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .lineupFocusLayer(episodeArtworkIsFocused, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if playback?.watched == true {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(LineupStyle.background)
                            .frame(width: 26, height: 26)
                            .background(LineupStyle.lightPurple, in: Circle())
                            .padding(8)
                    }
                }
            if let label = episode.episodeCode ?? episode.episodeLabel {
                Text(label).font(.inter(.caption, .semibold))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
            }
            Text(episode.name).font(.inter(.subheadline, .bold)).lineLimit(2)
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview).font(.inter(.caption))
                    .lineLimit(episodeArtworkIsFocused ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                    .animation(.easeInOut(duration: 0.2), value: episodeArtworkIsFocused)
            }
            if !footer.isEmpty {
                Text(footer).font(.inter(.caption2))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(LineupStyle.lightPurple)
    }

    private var episodeArtworkIsFocused: Bool {
        #if os(tvOS)
        artworkFocused
        #else
        false
        #endif
    }

    private var playbackPresentation: MediaCardPlayback? {
        media.cardPlayback(for: episode, asShow: false)
    }

    private var footer: String {
        [episode.formattedAirDate, episode.formattedRuntime]
            .compactMap { $0 }.joined(separator: "  \u{00B7}  ")
    }
}

private struct MediaPlayableCard: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.playMedia) private var playMedia
    let item: MediaItem
    var shape: MediaArtShape = .poster
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Only for a card shown outside the Library tab, which has no tab to
    /// hand the title to.
    @State private var choosingSource = false

    var body: some View {
        #if os(tvOS)
        TVSelectable(drawsFocusChrome: false, action: choose, onFocusChange: onFocusChange) {
            MediaItemCard(item: item, shape: shape)
        }
            .contextMenu { libraryActions }
            .fullScreenCover(isPresented: $choosingSource) {
                MediaSourcePicker(item: item)
            }
        #else
        Button(action: choose) { MediaItemCard(item: item, shape: shape) }
            .lineupFlatButton()
            .contextMenu { libraryActions }
            .sheet(isPresented: $choosingSource) {
                MediaSourcePicker(item: item)
            }
        #endif
    }

    /// The Library tab opens the streams, so the player outlives this card.
    private func choose() {
        if let playMedia { playMedia(item) } else { choosingSource = true }
    }

    private var libraryActions: some View { MediaCardActions(item: item) }
}

/// What a long press on a Library card offers: leaving Continue Watching,
/// and for an episode, watched and favorite. One list, whether the card opens
/// a page or the streams.
private struct MediaCardActions: View {
    @EnvironmentObject private var media: MediaLibrary
    let item: MediaItem

    var body: some View {
        if media.isInContinueWatching(item) {
            Button("Remove from Continue Watching", systemImage: "rectangle.stack.badge.minus", role: .destructive) {
                media.removeFromContinueWatching(item)
            }
            .lineupFlatButton()
        }
        if item.type == "Episode" {
            let watched = media.isWatched(item)
            Button(watched ? "Remove from Watched" : "Mark Watched", systemImage: watched ? "eye.slash" : "eye.fill") {
                Task { await media.setEpisodePlayedAndAdvance(!watched, for: item) }
            }
            .lineupFlatButton()
            let favorite = media.isLocalFavorite(item)
            Button(favorite ? "Remove from Favorites Library" : "Add to Favorites Library", systemImage: favorite ? "heart.slash" : "heart.fill") {
                media.setLocalFavorite(!favorite, for: item)
                Task { await media.setFavorite(!favorite, for: item) }
            }
            .lineupFlatButton()
        }
    }
}

#if os(tvOS)
/// Owns the rapidly changing focus preview outside the catalog view tree. A
/// remote move now redraws the two cinematic layers only; it does not ask
/// every shelf and poster to recompute while focus is in motion.
@MainActor
private final class TVMediaPreviewState: ObservableObject {
    @Published private(set) var item: MediaItem?
    private var details: [String: MediaItem] = [:]
    private var focusedPosterIDs: Set<String> = []
    private var detailLoad: Task<Void, Never>?

    var isNavigating: Bool { !focusedPosterIDs.isEmpty }

    func setInitial(_ initial: MediaItem?) {
        guard item == nil else { return }
        item = initial.flatMap { details[$0.libraryKey] } ?? initial
    }

    func reset(to initial: MediaItem?) {
        detailLoad?.cancel()
        focusedPosterIDs.removeAll()
        details.removeAll(keepingCapacity: true)
        item = initial
    }

    func focus(_ focusedItem: MediaItem, focused: Bool,
               load: @escaping @MainActor (MediaItem) async -> MediaItem?) {
        let key = focusedItem.libraryKey
        if focused { focusedPosterIDs.insert(key) }
        else { focusedPosterIDs.remove(key) }
        guard focused else { return }
        // Back on the title already shown: whatever was about to replace it
        // is no longer wanted.
        detailLoad?.cancel()
        guard item?.libraryKey != key else { return }
        detailLoad = Task { @MainActor [weak self] in
            // A swipe crosses several titles in a fraction of a second, and
            // each one swapped the whole screen's artwork and words -- a
            // full-screen picture fetched and decoded for a title the remote
            // had already left, while the posters waited behind it. The room
            // changes once the remote has stopped, which on a single press is
            // too soon to notice.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.item = self.details[key] ?? focusedItem
            guard self.details[key] == nil else { return }
            // Rich metadata waits a little longer again.
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard !Task.isCancelled, let loaded = await load(focusedItem),
                  !Task.isCancelled, self.item?.libraryKey == key else { return }
            self.details[key] = loaded
            self.item = loaded
        }
    }

    func rotate(to next: MediaItem,
                load: @escaping @MainActor (MediaItem) async -> MediaItem?) {
        let key = next.libraryKey
        detailLoad?.cancel()
        item = details[key] ?? next
        guard details[key] == nil else { return }
        detailLoad = Task { [weak self] in
            guard let loaded = await load(next), !Task.isCancelled,
                  self?.item?.libraryKey == key else { return }
            self?.details[key] = loaded
            self?.item = loaded
        }
    }
}

/// The only observer of focus-preview changes. Keeping this tiny boundary is
/// what lets the poster shelves stay still while the room behind them changes.
private struct TVMediaLibraryCanvas: View {
    @ObservedObject var preview: TVMediaPreviewState
    /// What the controls along the foot of the screen take; the title is
    /// told in the space above them.
    let bottomInset: CGFloat

    var body: some View {
        TVMediaCinematicBackdrop(item: preview.item)
            .overlay(alignment: .top) {
                TVMediaLibraryPreview(item: preview.item, steady: true)
                    .padding(.bottom, bottomInset)
                    .allowsHitTesting(false)
            }
    }
}

/// What the Library's prefetch follows: the shelf shown, and how many there
/// are to fetch from.
private struct TVShelfPrefetchKey: Equatable {
    let index: Int
    let count: Int
}

/// Where the Library's remote can be.
private enum TVLibraryFocus: Hashable {
    case hero
    case card(Int)
    /// The strip along the top of the shelf, which turns Up from a card
    /// into the shelf before.
    case shelfAbove
}

/// One shelf the Library's row can show.
private struct TVLibraryShelf: Identifiable {
    let id: String
    let title: String
    let label: String?
    let items: [MediaItem]
    /// Continue Watching opens a show's page rather than its streams.
    let opensPages: Bool
    let catalog: MediaCatalog?
}

/// The artwork plane behind both Library browsing and the selected-title page.
/// It is fixed while shelves move, so focus changes the room rather than
/// repainting a rectangle behind one row.
private struct TVMediaCinematicBackdrop: View {
    @EnvironmentObject private var media: MediaLibrary
    let item: MediaItem?

    var body: some View {
        // The picture fills the ground and is cut to it. Drawn as an overlay
        // it can't size the ground: filled straight into a stack, a picture
        // not the screen's shape -- a poster where there is no backdrop --
        // made the stack taller than the screen.
        LineupStyle.background
            .overlay {
                if let item {
                    LineupArtView(url: media.backdropURL(for: item, width: 1920)
                                  ?? media.imageURL(for: item, width: 1920), width: 1920) { loaded in
                        if let loaded { loaded.resizable().scaledToFill() }
                        else { Color.clear }
                    }
                    .id(item.id)
                    .transition(.opacity)
                }
            }
            .clipped()
            .overlay { shade }
            .animation(.easeInOut(duration: 0.32), value: item?.id)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// Dark from the left for the words, and from the foot for the shelf.
    private var shade: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.9), location: 0),
                .init(color: .black.opacity(0.58), location: 0.38),
                .init(color: .black.opacity(0.08), location: 0.78),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .clear, location: 0.42),
                .init(color: LineupStyle.background.opacity(0.42), location: 0.7),
                .init(color: LineupStyle.background.opacity(0.88), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Focused-title context that stays above the shelves. Sparse catalog entries
/// show what they have immediately; the detail fetch enriches the same view
/// with logo, cast and metadata without changing its geometry.
private struct TVMediaLibraryPreview: View {
    @EnvironmentObject private var media: MediaLibrary
    let item: MediaItem?
    /// Browsing: every title takes the same room, told from the top, so
    /// nothing moves as the remote goes from title to title or as a title's
    /// ratings, details and cast arrive -- each has its place kept for it,
    /// and only what is in it changes. The title page leaves this off and
    /// sits its words on the actions beneath them.
    var steady = false
    /// Each title's ratings once found. The hero moves on every few seconds
    /// and comes back round, and a title it has shown keeps its chips.
    @State private var ratings: [String: MediaRatings] = [:]

    var body: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 13) {
                    titleLockup(item)
                    ratingsRow(item)
                    metadataLine(item)
                    overviewText(item)
                    if steady {
                        Color.clear.frame(height: 44)
                            .overlay(alignment: .leading) { castLine(item) }
                    } else {
                        castLine(item)
                    }
                }
                .id(item.id)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: steady ? .topLeading : .bottomLeading)
                .padding(.horizontal, 72)
                .padding(.top, 112)
                .padding(.bottom, 24)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: item?.id)
        .task(id: item?.libraryKey) {
            guard let item else { return }
            let found = await media.ratings(for: item)
            ratings[item.libraryKey] = found
        }
    }

    @ViewBuilder
    private func titleLockup(_ item: MediaItem) -> some View {
        LineupArtView(url: media.logoURL(for: item, width: 620), width: 620) { loaded in
            if let loaded {
                loaded.resizable().scaledToFit()
            } else {
                Text(item.name)
                    .font(.inter(46, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.72), radius: 12, y: 3)
            }
        }
        .frame(width: 620, height: 105, alignment: .leading)
    }

    @ViewBuilder
    private func ratingsRow(_ item: MediaItem) -> some View {
        let shown = ratings[item.libraryKey] ?? media.knownRatings(for: item)
        if let shown, !shown.isEmpty {
            MediaRatingChips(ratings: shown)
        } else if steady {
            Color.clear.frame(height: MediaRatingMetrics.height)
        }
    }

    @ViewBuilder
    private func metadataLine(_ item: MediaItem) -> some View {
        let parts = metadata(item)
        if !parts.isEmpty || steady {
            Text(parts.isEmpty ? " " : parts.joined(separator: "  ·  "))
                .font(.inter(19, .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.75), radius: 10, y: 2)
        }
    }

    @ViewBuilder
    private func overviewText(_ item: MediaItem) -> some View {
        let overview = item.overview ?? ""
        if !overview.isEmpty || steady {
            Text(overview.isEmpty ? " " : overview)
                .font(.inter(18, .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3, reservesSpace: steady)
                .frame(maxWidth: 820, alignment: .leading)
                .shadow(color: .black.opacity(0.75), radius: 10, y: 2)
        }
    }

    /// The year, the genres and the running time, under the ratings.
    private func metadata(_ item: MediaItem) -> [String] {
        [item.productionYear.map(String.init),
         item.genres?.prefix(3).joined(separator: ", "),
         item.formattedRuntime,
         item.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func castLine(_ item: MediaItem) -> some View {
        let actors = Array((item.people ?? [])
            .filter { $0.type?.lowercased() == "actor" }.prefix(3))
        if !actors.isEmpty {
            HStack(spacing: 12) {
                HStack(spacing: -8) {
                    ForEach(actors) { person in
                        LineupArtView(url: media.personImageURL(for: person, of: item), width: 72) { loaded in
                            if let loaded { loaded.resizable().scaledToFill() }
                            else { Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.55)) }
                        }
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.62), in: Circle())
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                    }
                }
                Text(actors.map(\.name).joined(separator: ", "))
                    .font(.inter(15, .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
    }
}
#endif

/// A full-bleed top-ten carousel sourced from the catalog chosen in Account.
/// It advances gently when left alone. Changing the page by touch restarts the
/// eight-second interval, so it never fights a swipe or immediately skips the
/// title the viewer deliberately chose.
private struct MediaLibraryHero: View {
    @EnvironmentObject private var media: MediaLibrary
    let catalog: MediaCatalog
    let onOpen: (MediaItem) -> Void
    @State private var index = 0
    /// Each title's ratings once found, so a slide shown again has its chips.
    @State private var ratings: [String: MediaRatings] = [:]

    private var items: [MediaItem] {
        MediaHeroCatalogSelection.featuredItems(in: catalog)
    }

    var body: some View {
        Group {
            #if os(tvOS)
            if !items.isEmpty {
                heroSlide(item: items[index])
                    .overlay(alignment: .bottom) { pageIndicator }
            }
            #else
            if !items.isEmpty {
                GeometryReader { viewport in
                    TabView(selection: $index) {
                        ForEach(Array(items.enumerated()), id: \.element.libraryKey) { offset, item in
                            heroSlide(item: item, loadsArtwork: isAdjacentToCurrent(offset))
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .tag(offset)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .overlay(alignment: .bottom) { pageIndicator }
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
        #if os(tvOS)
        // Any focused control inside the hero participates in the same
        // carousel. A left/right press therefore changes the feature directly
        // instead of first requiring focus to land on a tiny chevron.
        .onMoveCommand { direction in
            switch direction {
            case .left: move(-1)
            case .right: move(1)
            default: break
            }
        }
        #endif
        .onChange(of: catalog.id) { _, _ in index = 0 }
        .onChange(of: items.count) { _, count in
            if count == 0 { index = 0 }
            else { index = min(index, count - 1) }
        }
        .task(id: index) {
            guard items.count > 1 else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { move(1) }
        }
        // The title on screen, then the one after it, so the next slide
        // arrives with its chips already found.
        .task(id: items.indices.contains(index) ? items[index].libraryKey : "") {
            for offset in [index, index + 1] where items.indices.contains(offset) {
                let item = items[offset]
                guard ratings[item.libraryKey] == nil else { continue }
                let found = await media.ratings(for: item)
                guard !Task.isCancelled else { return }
                ratings[item.libraryKey] = found
            }
        }
    }

    private func heroSlide(item: MediaItem, loadsArtwork: Bool = true) -> some View {
        GeometryReader { slide in
            let contentWidth = max(0, slide.size.width - heroHorizontalPadding * 2)
            let contentHeight = max(0, slide.size.height - heroTopPadding - heroBottomPadding)
            let readableWidth = min(copyWidth, contentWidth)

            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LineupArtView(url: loadsArtwork
                              ? (media.backdropURL(for: item, width: artWidth)
                                 ?? media.imageURL(for: item, width: artWidth))
                              : nil,
                              // Decode for the actual viewport, not the
                              // server request's pixel ceiling. On a 3x phone
                              // the old value produced a 3300-pixel image for
                              // a roughly 390-point hero and churned the image
                              // cache every time the carousel advanced.
                              width: slide.size.width) { image in
                    if let image { image.resizable().scaledToFill() }
                    else { Color.clear }
                }
                .frame(width: slide.size.width, height: slide.size.height)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.9), location: 0),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .clear, location: 0.86)
                ], startPoint: .leading, endPoint: .trailing)
                // Keep the picture alive almost to the first shelf, then finish
                // on the exact Library background at the seam. The older fade
                // became opaque too early and left a dead band above Continue
                // Watching even though the artwork itself filled the hero.
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.72),
                    .init(color: .black.opacity(0.12), location: 0.9),
                    .init(color: LineupStyle.background.opacity(0.25), location: 0.98),
                    .init(color: LineupStyle.background, location: 1)
                ], startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: heroSpacing) {
                    Spacer(minLength: 0)

                    Text(item.name)
                        .font(.inter(titleSize, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(width: readableWidth, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

                    if let shown = ratings[item.libraryKey] ?? media.knownRatings(for: item), !shown.isEmpty {
                        MediaRatingChips(ratings: shown)
                    }

                    if !metadata(for: item).isEmpty {
                        Text(metadata(for: item).joined(separator: "  ·  "))
                            .font(.inter(metaSize, .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .frame(width: readableWidth, alignment: .leading)
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.inter(overviewSize))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(overviewLines)
                            .frame(width: readableWidth, alignment: .leading)
                    }

                    #if os(tvOS)
                    MediaHeroButton(title: item.hasDetailPage ? "Details" : "Play",
                                    symbol: item.hasDetailPage ? "info.circle.fill" : "play.fill") {
                        onOpen(item)
                    }
                    .frame(width: min(buttonMaxWidth, contentWidth), alignment: .leading)
                    #endif
                }
                // This frame is explicit rather than an ideal/max width. A
                // long title can wrap inside it, but can never make a TabView
                // page wider and move its leading edge off screen again.
                .frame(width: contentWidth, height: contentHeight, alignment: .bottomLeading)
                .padding(.horizontal, heroHorizontalPadding)
                .padding(.top, heroTopPadding)
                .padding(.bottom, heroBottomPadding)
            }
            .frame(width: slide.size.width, height: slide.size.height)
            .clipped()
        }
        .contentShape(Rectangle())
        #if !os(tvOS)
        // Paging still belongs to the horizontal drag. A release without a
        // drag opens the title, which makes the artwork itself the familiar
        // iPhone affordance and removes the redundant Details button.
        .onTapGesture { onOpen(item) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.hasDetailPage ? "View details for \(item.name)" : "Play \(item.name)")
        #endif
    }

    /// The year, the genres and the running time, under the ratings.
    private func metadata(for item: MediaItem) -> [String] {
        [item.productionYear.map(String.init),
         item.genres?.prefix(3).joined(separator: ", "),
         item.formattedRuntime]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    private func isAdjacentToCurrent(_ page: Int) -> Bool {
        guard items.count > 2 else { return true }
        let distance = abs(page - index)
        return distance <= 1 || distance == items.count - 1
    }

    #if os(tvOS)
    private var artWidth: Int { 1800 }
    // From the physical top edge through the tab-bar chrome and down to the
    // first shelf, this gives tvOS the same cinematic proportion as iPhone.
    private var heroHeight: CGFloat { 700 }
    private var heroHorizontalPadding: CGFloat { 72 }
    private var heroTopPadding: CGFloat { 40 }
    private var heroBottomPadding: CGFloat { 76 }
    private var heroSpacing: CGFloat { 10 }
    private var titleSize: CGFloat { 48 }
    private var metaSize: CGFloat { 16 }
    private var overviewSize: CGFloat { 17 }
    private var overviewLines: Int { 2 }
    private var copyWidth: CGFloat { 720 }
    private var buttonMaxWidth: CGFloat { 190 }
    #else
    private var artWidth: Int { 1100 }
    private var heroHeight: CGFloat { 500 }
    private var heroHorizontalPadding: CGFloat { 22 }
    // Artwork runs behind the status/navigation area; copy begins below it.
    private var heroTopPadding: CGFloat { 86 }
    private var heroBottomPadding: CGFloat { 58 }
    private var heroSpacing: CGFloat { 7 }
    private var titleSize: CGFloat { 34 }
    private var metaSize: CGFloat { 13 }
    private var overviewSize: CGFloat { 14 }
    private var overviewLines: Int { 2 }
    private var copyWidth: CGFloat { 390 }
    private var buttonMaxWidth: CGFloat { 145 }
    #endif

    private var pageIndicator: some View {
        HStack(spacing: 5) {
            ForEach(items.indices, id: \.self) { page in
                Capsule()
                    .fill(.white.opacity(page == index ? 0.92 : 0.3))
                    .frame(width: page == index ? 18 : 5, height: 5)
            }
        }
        #if os(tvOS)
        .padding(.bottom, 28)
        #else
        .padding(.bottom, 18)
        #endif
        .animation(.easeOut(duration: 0.2), value: index)
        .accessibilityHidden(true)
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }
}

private struct MediaHeroButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, action: action) { label }
        #else
        Button(action: action) { label }.lineupFlatButton()
        #endif
    }

    private var label: some View {
        Label(title, systemImage: symbol)
            .font(.inter(buttonFont, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, buttonInset)
            .frame(height: buttonHeight)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
    }

    #if os(tvOS)
    private var buttonFont: CGFloat { 17 }
    private var buttonInset: CGFloat { 18 }
    private var buttonHeight: CGFloat { 50 }
    #else
    private var buttonFont: CGFloat { 14 }
    private var buttonInset: CGFloat { 13 }
    private var buttonHeight: CGFloat { 42 }
    #endif
}

/// Account owns personalization; the Library hero only presents the result.
/// Keeping the choice here also gives it enough room to explain how many of a
/// shelf's titles will be used instead of putting a settings icon over art.
struct LibraryHeroSettingsView: View {
    @EnvironmentObject private var media: MediaLibrary

    /// Something the hero can feature: a shelf already on the Library, or
    /// any list the Library could add as one.
    private struct Choice: Identifiable {
        enum Pick {
            case shelf(MediaCatalog)
            case list(LibraryHeroSource)
        }
        let id: String
        let title: String
        let detail: String?
        let pick: Pick
    }

    private struct ChoiceGroup: Identifiable {
        let id: String
        let title: String
        let detail: String?
        /// The logo of the server the group is named for.
        var brand: MediaServerBrand? = nil
        let choices: [Choice]
    }

    /// The shelves first, then every list Add Shelf offers, grouped the way
    /// it groups them.
    private var groups: [ChoiceGroup] {
        var groups: [ChoiceGroup] = []
        let shelves = media.catalogs.filter { !$0.items.isEmpty }.map { catalog in
            Choice(id: catalog.id, title: media.shelfTitle(catalog),
                   detail: [featured(catalog.items.count), media.serverName(for: catalog)]
                       .compactMap { $0 }.joined(separator: " · "),
                   pick: .shelf(catalog))
        }
        groups.append(ChoiceGroup(id: "shelves", title: "YOUR SHELVES", detail: "Already in the Library",
                                  choices: shelves))
        let several = media.profiles.count > 1
        for server in media.profiles {
            let owner = several ? " · " + server.name.uppercased() : ""
            let brand = several ? MediaServerBrand.of(server) : nil
            groups.append(ChoiceGroup(id: server.id.uuidString + "|libraries", title: "LIBRARIES" + owner,
                                      detail: nil, brand: brand,
                                      choices: media.availableLibraries(on: server).map(rootChoice)))
            groups.append(ChoiceGroup(id: server.id.uuidString + "|catalogs", title: "IMPORTED CATALOGS" + owner,
                                      detail: nil, brand: brand,
                                      choices: media.availableCatalogs(on: server).map(rootChoice)))
        }
        if let name = media.providerVOD.profile?.name {
            let categories = media.availableProviderShelves
            groups.append(ChoiceGroup(id: "provider|films", title: "MOVIES · " + name.uppercased(),
                                      detail: "Film categories from your IPTV provider",
                                      choices: categories.films.map(rootChoice)))
            groups.append(ChoiceGroup(id: "provider|shows", title: "SERIES · " + name.uppercased(),
                                      detail: "Series categories from your IPTV provider",
                                      choices: categories.shows.map(rootChoice)))
        }
        for section in MDBListCatalogSection.allCases {
            let lists = media.availableMDBListCatalogs.filter { $0.section == section }
            groups.append(ChoiceGroup(id: "mdblist|" + section.rawValue, title: section.title,
                                      detail: section.detail,
                                      choices: lists.map { list in
                                          Choice(id: list.shelfID, title: list.name,
                                                 detail: list.itemCount.map { "\($0) list titles" },
                                                 pick: .list(LibraryHeroSource(mdbListID: list.id, name: list.name)))
                                      }))
        }
        return groups.filter { !$0.choices.isEmpty }
    }

    private func rootChoice(_ root: MediaItem) -> Choice {
        Choice(id: MediaCatalog.id(for: root), title: root.name,
               detail: root.childCount.map { $0 == 1 ? "1 title" : "\($0) titles" },
               pick: .list(LibraryHeroSource(root: root, name: root.name)))
    }

    private func featured(_ count: Int) -> String {
        let shown = min(10, count)
        return "\(shown) featured title\(shown == 1 ? "" : "s")"
    }

    private func choose(_ choice: Choice) {
        switch choice.pick {
        case .shelf(let catalog): media.selectHeroCatalog(catalog)
        case .list(let source): Task { await media.selectHeroSource(source) }
        }
    }

    /// The lists that are read on request, so every one is offered.
    private func loadSources() async {
        async let mdbList: Void = media.loadMDBListIntegration()
        async let provider: Void = media.loadProviderCatalog()
        _ = await (mdbList, provider)
    }

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageTitle(eyebrow: "Library", title: "Library Hero",
                          detail: "Choose any list. Its first ten titles fill the Library hero.")
                if groups.isEmpty {
                    ContentUnavailableView("No Lists", systemImage: "rectangle.stack.badge.plus",
                        description: Text("Add a media server, then choose a list here."))
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .mediaFocusAnchor()
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 14) {
                            groupHeading(group)
                            ForEach(group.choices) { choice in
                                TVSelectable(scale: LineupStyle.controlLift, action: { choose(choice) }) {
                                    choiceRow(choice)
                                }
                            }
                        }
                        .lineupFocusRegion()
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 70).padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(LineupStyle.background.ignoresSafeArea())
        .task { await loadSources() }
        #else
        List {
            if groups.isEmpty {
                ContentUnavailableView("No Lists", systemImage: "rectangle.stack.badge.plus",
                    description: Text("Add a media server, then choose a list here."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.choices) { choice in
                            Button { choose(choice) } label: { choiceRow(choice) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        groupHeading(group)
                    } footer: {
                        if group.id == groups.first?.id {
                            Text("The first ten titles of the list you choose become the swipeable Library hero.")
                        }
                    }
                    .listRowBackground(LineupPanelStyle.listCard)
                    .listRowSeparatorTint(LineupPanelStyle.listSeparator)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LineupPanelStyle.listGround)
        .navigationTitle("Library Hero")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSources() }
        #endif
    }

    private func groupHeading(_ group: ChoiceGroup) -> some View {
        HStack(spacing: 7) {
            if let brand = group.brand {
                MediaServerLogo(brand: brand).frame(width: headingLogoSize, height: headingLogoSize)
            }
            #if os(tvOS)
            Text(group.title)
                .font(.inter(headingSize, .heavy)).tracking(1.4)
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
                .lineLimit(1)
            #else
            Text(group.title).modifier(LineupGroupHeading()).lineLimit(1)
            #endif
        }
        .textCase(nil)
    }

    private func choiceRow(_ choice: Choice) -> some View {
        let selected = media.heroCatalog?.id == choice.id
        let busy = media.loadingHeroSource == choice.id
        return HStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: rowSymbolSize, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? LineupStyle.highlight : LineupStyle.secondary)
                .frame(width: rowSymbolFrame)
            VStack(alignment: .leading, spacing: 4) {
                Text(choice.title).font(.inter(rowTitleSize, .semibold)).lineLimit(1)
                if let detail = choice.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.inter(rowDetailSize))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.58))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if busy {
                ProgressView().controlSize(.small)
            } else if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: checkSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(LineupStyle.highlight)
                    .accessibilityLabel("Selected")
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, rowHorizontalPadding)
        .frame(minHeight: rowHeight)
        #if os(tvOS)
        .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(LineupStyle.line, lineWidth: 1))
        #endif
        .contentShape(Rectangle())
    }

    #if os(tvOS)
    private var rowSymbolSize: CGFloat { 25 }
    private var rowSymbolFrame: CGFloat { 42 }
    private var rowTitleSize: CGFloat { 21 }
    private var rowDetailSize: CGFloat { 15 }
    private var checkSize: CGFloat { 24 }
    private var rowHorizontalPadding: CGFloat { 24 }
    private var rowHeight: CGFloat { 82 }
    private var headingSize: CGFloat { 13 }
    private var headingLogoSize: CGFloat { 16 }
    #else
    private var rowSymbolSize: CGFloat { 20 }
    private var rowSymbolFrame: CGFloat { 30 }
    private var rowTitleSize: CGFloat { 16 }
    private var rowDetailSize: CGFloat { 13 }
    private var checkSize: CGFloat { 20 }
    private var rowHorizontalPadding: CGFloat { 0 }
    private var rowHeight: CGFloat { 58 }
    private var headingSize: CGFloat { 11 }
    private var headingLogoSize: CGFloat { 13 }
    #endif
}

/// One place asked for a title's streams: a media server, or the IPTV
/// provider.
private enum StreamLookup {
    case server(MediaServerProfile)
    case provider(id: UUID, name: String)

    var id: UUID {
        switch self {
        case .server(let server): server.id
        case .provider(let id, _): id
        }
    }

    /// The server's logo; the provider, not a media server, has none.
    var brand: MediaServerBrand? {
        switch self {
        case .server(let server): MediaServerBrand.of(server)
        case .provider: nil
        }
    }

    /// The tab it is listed under: a server by its name, the provider as
    /// VOD -- the name its streams are grouped under.
    var name: String {
        switch self {
        case .server(let server): server.name
        case .provider: "VOD"
        }
    }
}

/// How one server's search for a title's streams went.
private struct StreamServerStatus: Identifiable {
    enum Phase {
        case looking
        /// Waiting on what the looking needs first, and saying so: the IPTV
        /// provider's list, read from the device or downloaded.
        case preparing(String)
        case found(Int)
        /// Carries how the title was looked for there.
        case notOnServer(tried: String)
        case failed(String)
    }

    let id: UUID
    let name: String
    /// The server's logo; nil for VOD, which is the IPTV provider's.
    var brand: MediaServerBrand? = nil
    var phase: Phase

    var detail: String {
        switch phase {
        case .looking: "Looking…"
        case .preparing(let note): note
        case .found(let count): count == 0 ? "No streams" : (count == 1 ? "1 stream" : "\(count) streams")
        case .notOnServer: "Doesn't have this title"
        case .failed(let message): "Didn't answer · " + message
        }
    }

    /// How a server that has no copy of the title was asked for one.
    var tried: String? {
        if case .notOnServer(let tried) = phase { return tried }
        return nil
    }

    var symbol: String {
        switch phase {
        case .looking, .preparing: "hourglass"
        case .found(let count): count > 0 ? "checkmark.circle.fill" : "minus.circle"
        case .notOnServer: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var isGood: Bool {
        if case .found(let count) = phase { return count > 0 }
        return false
    }

    /// Still asking, or still getting ready to.
    var isWaiting: Bool {
        switch phase {
        case .looking, .preparing: true
        default: false
        }
    }

    var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    /// What went wrong, for a server that did not answer.
    var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// What its tab says after its name.
    var mark: MediaStreamTab.Mark {
        switch phase {
        case .looking, .preparing: .looking
        case .found(let count): .count(count)
        case .notOnServer: .missing
        case .failed: .failed
        }
    }
}

extension Notification.Name {
    /// An episode ended with nothing after it: the Library goes back to its
    /// front page.
    static let lineupReturnToLibraryFront = Notification.Name("Lineup.returnToLibraryFront")
}

private struct MediaSourcePicker: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    /// The title the streams are for. An episode's end can move it on to the
    /// next one, so the list follows the viewer from one to the next.
    @State private var item: MediaItem
    /// Play from the beginning rather than from the saved place.
    @State private var startsOver: Bool
    /// The episode after this one, when there is one to play, for the
    /// player's Next Episode and for where this one's end leads.
    @State private var nextEpisode: MediaItem?
    /// What the player's closing leads to, set as it closes.
    @State private var advance: Advance?
    /// Play the best stream as soon as it is known: Next Episode was chosen.
    @State private var autoPicks = false

    private enum Advance {
        case playNext(MediaItem)
        case reachedEnd
    }

    init(item: MediaItem, startsOver: Bool = false) {
        _item = State(initialValue: item)
        _startsOver = State(initialValue: startsOver)
    }
    /// Set when the picker went straight to the only stream there was, so
    /// closing the player closes the picker too, rather than leaving a list
    /// of one to back out of.
    @State private var playedOnlySource = false
    @State private var sources: [MediaPlaybackSource] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedSource: MediaPlaybackSource?
    @State private var providerFilter: String?
    /// Servers still being asked. What the others found is listed meanwhile.
    @State private var pendingServers = 0
    /// How each server's search for this title went, said at the top of the
    /// list so a server that added nothing says why.
    @State private var serverStatus: [StreamServerStatus] = []

    var body: some View {
        #if os(tvOS)
        // No NavigationStack: its bar is what drew the oversized title and the
        // Close button. The remote's Menu button is how a viewer leaves a
        // screen on this platform.
        board
            .onExitCommand { dismiss() }
            .task(id: item.libraryKey) { await loadSources() }
            .task(id: item.libraryKey) {
                nextEpisode = nil
                nextEpisode = await media.episodeAfter(item)
            }
            .fullScreenCover(item: $selectedSource, onDismiss: playerClosed) { source in
                playback(for: source)
            }
        #else
        NavigationStack {
            board
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close", action: dismiss.callAsFunction) }
                }
        }
        .task(id: item.libraryKey) { await loadSources() }
        .fullScreenCover(item: $selectedSource) { source in playback(for: source) }
        #endif
    }

    #if os(tvOS)
    /// Where the player's closing leads. Next Episode plays the next one on
    /// its best stream. An episode that ran to its end without it leads to
    /// the next one's streams to choose from, or, with none after it, back to
    /// the Library's front page. Backing out of the player is where it was.
    private func playerClosed() {
        let step = advance
        advance = nil
        switch step {
        case .playNext(let next)?:
            lead(to: next, playing: true)
        case .reachedEnd?:
            if let next = nextEpisode {
                lead(to: next, playing: false)
            } else if item.type == "Episode" {
                dismiss()
                // Once this screen has gone, so the pages under it are not
                // taken away while it is still leaving.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: .lineupReturnToLibraryFront, object: nil)
                }
            } else if playedOnlySource {
                dismiss()
            }
        case nil:
            if playedOnlySource { dismiss() }
        }
    }

    private func lead(to next: MediaItem, playing: Bool) {
        autoPicks = playing
        playedOnlySource = false
        startsOver = false
        nextEpisode = nil
        item = next
    }

    /// The best stream, as soon as it is known: the first place in the list's
    /// order to answer with streams, once every place before it has answered
    /// with none. Waiting for the slowest server would hold Next Episode up
    /// for a stream that would be listed below the one in hand.
    private static func bestSource(found: [Int: [MediaPlaybackSource]], places: Int) -> MediaPlaybackSource? {
        for index in 0..<places {
            guard let streams = found[index] else { return nil }
            if let best = MediaStreamSection.sections(of: streams).first?.sources.first { return best }
        }
        return nil
    }
    #endif

    private var board: some View {
        MediaStreamBoard(heading: heading, statuses: serverStatus, sources: sources,
                         loading: loading, error: error, filter: $providerFilter,
                         choose: { selectedSource = $0 })
    }

    /// What the list is for: an episode as its show, number and name, a film
    /// as its name, year and length. The art behind it is the title's own
    /// wide picture -- an episode's still when it has no other -- and never a
    /// poster stretched across the screen.
    private var heading: MediaStreamHeading {
        let line = { (parts: [String?]) -> String? in
            let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            return text.isEmpty ? nil : text
        }
        let backdrop = media.backdropURL(for: item, width: 1920)
            ?? (item.type == "Episode" ? media.imageURL(for: item, width: 1920) : nil)
        if let series = item.seriesName, !series.isEmpty {
            return MediaStreamHeading(title: series, subtitle: line([item.episodeCode, item.name]),
                                      backdrop: backdrop)
        }
        return MediaStreamHeading(title: item.name,
                                  subtitle: line([item.productionYear.map(String.init), item.formattedRuntime]),
                                  backdrop: backdrop)
    }

    /// Every connected server is asked at once: the title's own server about
    /// the title, each other server about its own copy of it. Streams are
    /// listed as they arrive -- the IPTV provider's first, then the title's
    /// own server's, then the others in the order they were added -- rather
    /// than held for the slowest server.
    @MainActor
    private func loadSources() async {
        loading = true
        error = nil
        sources = []
        providerFilter = nil
        let library = media
        let title = item
        // Every server, each about its own copy, and the IPTV provider ahead
        // of them all: its copies are in hand at once and play straight from
        // it. The title's own place -- its server, or the provider for one of
        // the provider's own titles -- failing is the screen's error.
        var lookups = library.streamServers(for: title).map { StreamLookup.server($0) }
        var ownIndex = 0
        if let provider = library.streamProvider(for: title) {
            lookups.insert(.provider(id: provider.id, name: provider.name), at: 0)
            if !title.isProviderTitle, lookups.count > 1 { ownIndex = 1 }
        }
        pendingServers = lookups.count
        let providerWait = library.providerVOD.waitNote
        serverStatus = lookups.map { lookup -> StreamServerStatus in
            var phase = StreamServerStatus.Phase.looking
            if case .provider = lookup, let providerWait { phase = .preparing(providerWait) }
            return StreamServerStatus(id: lookup.id, name: lookup.name, brand: lookup.brand, phase: phase)
        }
        var found: [Int: [MediaPlaybackSource]] = [:]
        var failure: Error?
        await withTaskGroup(of: (Int, Result<[MediaPlaybackSource], Error>).self) { group in
            for (index, lookup) in lookups.enumerated() {
                group.addTask {
                    do {
                        switch lookup {
                        case .server(let server):
                            return (index, .success(try await library.playbackSources(for: title, on: server)))
                        case .provider:
                            return (index, .success(try await library.providerSources(for: title)))
                        }
                    } catch { return (index, .failure(error)) }
                }
            }
            for await (index, answer) in group {
                pendingServers -= 1
                switch answer {
                case .success(let streams):
                    found[index] = streams
                    serverStatus[index].phase = .found(streams.count)
                // The title's own place failing is the error for the screen.
                // Any server's outcome is said in its tab at the top.
                case .failure(let problem):
                    found[index] = found[index] ?? []
                    if index == ownIndex { failure = problem }
                    if let miss = problem as? MediaLibrary.StreamLookupError {
                        serverStatus[index].phase = .notOnServer(tried: miss.tried)
                    } else if !MediaLibrary.isCancellation(problem) {
                        serverStatus[index].phase = .failed(problem.localizedDescription)
                    }
                }
                sources = found.keys.sorted().flatMap { found[$0] ?? [] }
                if !sources.isEmpty { loading = false }
                #if os(tvOS)
                if autoPicks, selectedSource == nil,
                   let best = Self.bestSource(found: found, places: lookups.count) {
                    autoPicks = false
                    playedOnlySource = true
                    // After a moment, as below: a cover asked for while this
                    // screen is still arriving is dropped.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        if selectedSource == nil { selectedSource = best }
                    }
                }
                #endif
            }
        }
        #if os(tvOS)
        // Nothing to play: the list says so, and the viewer chooses from here.
        autoPicks = false
        #endif
        guard !Task.isCancelled else { return }
        if sources.isEmpty, let failure { error = failure.localizedDescription }
        pendingServers = 0
        loading = false
        #if os(tvOS)
        // One stream is not a choice: play it. After a moment, so this screen
        // has finished arriving -- a cover asked for mid-presentation is
        // dropped rather than shown.
        if sources.count == 1, error == nil, selectedSource == nil, !playedOnlySource {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            playedOnlySource = true
            selectedSource = sources.first
        }
        #endif
    }

    // The synopsis type and the player that shows it are both iPhone-only;
    // tvOS has its own player and never builds this.
    #if !os(tvOS)
    /// What is playing, for the panel the player shows with its controls. The
    /// player is handed a URL and a name; everything else about the title lives
    /// here, so it is gathered here.
    private var playerSynopsis: MobilePlayerSynopsis {
        let heading: String?
        if let series = item.seriesName, !series.isEmpty {
            heading = [series, item.episodeCode, item.name]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            heading = item.name
        }
        let detail = [item.formattedAirDate.map { "Aired \($0)" } ?? item.productionYear.map(String.init),
                      item.formattedRuntime,
                      item.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return MobilePlayerSynopsis(heading: heading,
                                    detail: detail.isEmpty ? nil : detail,
                                    overview: item.overview)
    }
    #endif

    #if os(tvOS)
    /// An episode reads as its show, its number and its name; a film as its
    /// name, its year, its length and its rating.
    private var tvPlayerSynopsis: TVPlayerSynopsis {
        let facts = { (parts: [String?]) -> String? in
            let line = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            return line.isEmpty ? nil : line
        }
        if let series = item.seriesName, !series.isEmpty {
            return TVPlayerSynopsis(
                title: series,
                subtitle: facts([item.episodeCode, item.name]),
                detail: facts([item.formattedAirDate.map { "Aired \($0)" }, item.formattedRuntime,
                               item.officialRating]))
        }
        return TVPlayerSynopsis(
            title: item.name,
            subtitle: facts([item.productionYear.map(String.init), item.formattedRuntime, item.officialRating]),
            detail: item.overview)
    }
    #endif

    @ViewBuilder
    private func playback(for source: MediaPlaybackSource) -> some View {
        if let url = media.playbackURL(for: item, source: source) {
            #if os(tvOS)
            PlayerView(urls: [url], title: item.name, isLive: false,
                       initialPosition: startsOver ? nil : media.resumePosition(for: item),
                       onProgress: { position, duration in
                           media.trackPlayback(of: item, position: position, duration: duration)
                       },
                       synopsis: tvPlayerSynopsis,
                       nextEpisode: nextEpisode.map { next in
                           TVNextEpisodeOffer(code: next.episodeCode, title: next.name) {
                               advance = .playNext(next)
                           }
                       },
                       onReachedEnd: { if advance == nil { advance = .reachedEnd } })
            // After the player's own last report, which it makes as it goes.
            .onDisappear { DispatchQueue.main.async { media.flushLocalPlayback() } }
            #else
            MobilePlayerView(name: item.name, urls: [url], isLive: false,
                             sourceBitrate: source.formattedBitrate,
                             sourceQuality: source.quality,
                             synopsis: playerSynopsis,
                             // Start Over starts over here too; it resumed.
                             initialPosition: startsOver ? nil : media.resumePosition(for: item)) { position, duration in
                media.trackPlayback(of: item, position: position, duration: duration)
            }
            .onDisappear { DispatchQueue.main.async { media.flushLocalPlayback() } }
            #endif
        } else {
            ContentUnavailableView("Playback Unavailable", systemImage: "play.slash")
        }
    }

}

/// The chip draws its own selection and its own focus, so a remote moving across
/// the row reads the same as a finger tapping one.
/// tvOS lights whatever has focus by drawing a white plate behind it, sized to
/// the whole control. On a poster that plate covers the title under the art as
/// well, and white belongs to no part of this palette. Every focusable thing in
/// these screens turns that effect off and draws its own focus instead: the
/// cards and rows already did, and this is what the chrome around them uses.
/// Something for the remote to hold on to while a screen has nothing else.
///
/// tvOS cannot leave focus nowhere. A pushed screen that is still loading -- or
/// one showing "nothing here" -- contains no focusable view at all, so the
/// engine hands focus back to the tab bar: the bar the viewer cannot see
/// appears to have swallowed their press, and the next press moves them to
/// another tab entirely. That is the whole of the bug where browsing the media
/// tab would suddenly land somewhere else.
///
/// This draws nothing and does nothing. It exists so focus has a home on a
/// screen that is between states, and it goes away with the state that needed
/// it, by which time there is real content to take focus.
extension View {
    func mediaFocusAnchor() -> some View {
        #if os(tvOS)
        overlay(alignment: .center) {
            Color.clear.frame(width: 1, height: 1).focusable()
        }
        #else
        self
        #endif
    }
}

private struct MediaChromeSurface: ViewModifier {
    var focused = false
    var prominent = false
    /// A field the viewer types into. It marks focus with its edge only: filling
    /// it would put dark text on a light field mid-sentence, which is the same
    /// jarring inversion this is all here to remove.
    var outline = false
    var radius: CGFloat = 12

    // The search field and the rest of the media chrome sit on the same glass
    // as the player's controls and the Account tab. A prominent control is the
    // exception: it is a call to action and stays filled, because glass is a
    // surface to read through and that one is meant to be looked at.
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if filled {
            content
                .foregroundStyle(LineupStyle.background)
                .background(LineupStyle.lightPurple, in: shape)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
        } else {
            content
                .foregroundStyle(LineupStyle.lightPurple)
                .lineupLiquidGlass(shape, fallback: LineupStyle.surface, border: border)
                .lineupFocusLayer(focused, in: shape)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
        }
    }

    // Focus marks the edge. Only a deliberate call to action fills, and it
    // fills whether or not it happens to be focused, so focus never turns a
    // control into a pale slab.
    private var filled: Bool { !outline && prominent }

    // Constant: a control must look the same whether or not it holds focus.
    private var border: Color { prominent ? .clear : LineupStyle.line }
}

/// The same surface, reading focus from the button wrapped around it rather
/// than being told. A Menu's label cannot read focus this way, so the two menus
/// carry their own focus binding instead.
private struct MediaChromeFocus: ViewModifier {
    @Environment(\.isFocused) private var focused
    var prominent = false

    func body(content: Content) -> some View {
        content
            .modifier(MediaChromeSurface(focused: focused, prominent: prominent))
            .scaleEffect(focused ? LineupStyle.controlLift : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }
}

/// Padded chrome -- Add Shelf, See All, remove -- around a focusable button.
private struct MediaChromeLabel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 7)
            .modifier(MediaChromeFocus())
    }
}

// MARK: - The stream list

/// What a stream list is for, drawn at its top.
private struct MediaStreamHeading {
    let title: String
    let subtitle: String?
    let backdrop: URL?
}

/// One part of the stream list: the IPTV provider's copies, or one server's
/// streams, ranked by that server's score, highest first.
private struct MediaStreamSection: Identifiable {
    let title: String
    let sources: [MediaPlaybackSource]
    var id: String { title }

    /// By where each stream comes from -- VOD first, then the servers in the
    /// order they answered -- and each ranked by its own server's score.
    /// Scores are never compared across servers: StreamNZB's run to the tens
    /// of thousands and AIOStreams' to the hundreds, so a list mixing them
    /// ranks nothing; it only puts one server above the other.
    static func sections(of sources: [MediaPlaybackSource]) -> [MediaStreamSection] {
        var order: [String] = []
        var grouped: [String: [MediaPlaybackSource]] = [:]
        for source in sources {
            if grouped[source.group] == nil { order.append(source.group) }
            grouped[source.group, default: []].append(source)
        }
        return (order.filter { $0 == "VOD" } + order.filter { $0 != "VOD" }).map { group in
            MediaStreamSection(title: group, sources: MediaPlaybackSource.ranked(grouped[group] ?? []))
        }
    }
}

/// The stream list as it is drawn: the title it is for, a tab for each place
/// that was asked, and what they found -- each server's streams ranked by its
/// score, each row leading with what a stream is chosen by. Everything comes
/// from the picker, which does the asking; nothing here goes to a server.
private struct MediaStreamBoard: View {
    let heading: MediaStreamHeading
    let statuses: [StreamServerStatus]
    let sources: [MediaPlaybackSource]
    let loading: Bool
    let error: String?
    @Binding var filter: String?
    let choose: (MediaPlaybackSource) -> Void

    private typealias Style = MediaStreamStyle

    private var visible: [MediaPlaybackSource] {
        guard let filter else { return sources }
        return sources.filter { $0.group == filter }
    }

    private var selectedStatus: StreamServerStatus? {
        filter.flatMap { name in statuses.first { $0.name == name } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if statuses.count > 1 { tabs }
                list
            }
            .frame(maxWidth: Style.boardWidth, alignment: .leading)
            .padding(.horizontal, Style.sideInset)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Style.bottomInset)
            // Part of what scrolls, so it leaves with the title and the rows
            // below the first screen sit on a plain background.
            .background(alignment: .top) { MediaStreamBackdrop(url: heading.backdrop) }
        }
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Style.headerGap) {
            Text("CHOOSE A STREAM")
                .font(.inter(Style.eyebrowSize, .heavy)).tracking(Style.eyebrowTracking)
                .foregroundStyle(Style.caption)
            Text(heading.title)
                .font(.inter(Style.titleSize, .bold))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let subtitle = heading.subtitle {
                Text(subtitle)
                    .font(.inter(Style.subtitleSize))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 14, y: 2)
        .padding(.top, Style.headerTop).padding(.bottom, Style.headerBottom)
    }

    // MARK: Tabs

    /// One tab for everything, then one for each place asked -- each server,
    /// and VOD -- saying how its search is going: still looking, how many it
    /// found, or that it has none.
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Style.tabGap) {
                tab(nil, title: "All", mark: allMark)
                ForEach(statuses) { status in
                    tab(status.name, title: status.name, mark: status.mark, brand: status.brand)
                }
            }
            .padding(.vertical, Style.tabLift)
        }
        .scrollClipDisabled()
        .lineupFocusRegion()
        .padding(.bottom, Style.tabsBottom)
    }

    private var allMark: MediaStreamTab.Mark {
        sources.isEmpty && statuses.contains(where: \.isWaiting) ? .looking : .count(sources.count)
    }

    private func tab(_ value: String?, title: String, mark: MediaStreamTab.Mark,
                     brand: MediaServerBrand? = nil) -> some View {
        Button { filter = value } label: {
            MediaStreamTab(title: title, mark: mark, active: filter == value, brand: brand)
        }
        .lineupFlatButton()
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let shown = visible
        if shown.isEmpty {
            emptyState
        } else {
            let sections = MediaStreamSection.sections(of: shown)
            LazyVStack(alignment: .leading, spacing: Style.rowSpacing) {
                ForEach(sections) { section in
                    if sections.count > 1 {
                        sectionHeader(section, first: section.id == sections.first?.id)
                    }
                    ForEach(section.sources) { source in
                        row(source)
                    }
                }
            }
            if filter == nil { missingFooter }
        }
    }

    private func sectionHeader(_ section: MediaStreamSection, first: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let brand = statuses.first(where: { $0.name == section.title })?.brand {
                MediaServerLogo(brand: brand)
                    .frame(width: Style.sectionSize + 2, height: Style.sectionSize + 2)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            }
            Text(section.title.uppercased())
                .font(.inter(Style.sectionSize, .heavy)).tracking(Style.eyebrowTracking)
            Spacer()
            Text("\(section.sources.count)")
                .font(.interDigits(Style.sectionSize, .heavy))
        }
        .foregroundStyle(Style.sectionCaption)
        .padding(.horizontal, Style.rowInsetH)
        .padding(.top, first ? 0 : Style.sectionGap - Style.rowSpacing)
    }

    @ViewBuilder
    private func row(_ source: MediaPlaybackSource) -> some View {
        let label = MediaStreamRow(source: source)
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.cardLift, fillRadius: Style.rowRadius, action: { choose(source) }) {
            label
        }
        #else
        Button { choose(source) } label: { label }
            .lineupFlatButton()
        #endif
    }

    /// The places that added nothing, and why, under everything the others
    /// found -- so a server that should have had the title says how it was
    /// asked, without standing between the viewer and a stream.
    @ViewBuilder
    private var missingFooter: some View {
        let missing = statuses.filter { $0.tried != nil || $0.failure != nil }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: Style.lineGap * 2) {
                ForEach(missing) { status in
                    VStack(alignment: .leading, spacing: Style.lineGap) {
                        HStack(spacing: 6) {
                            if let brand = status.brand {
                                MediaServerLogo(brand: brand).frame(width: Style.noteSize, height: Style.noteSize)
                            }
                            Text(status.failure == nil ? "\(status.name) doesn't have this title"
                                                       : "\(status.name) didn't answer")
                                .font(.inter(Style.noteSize, .semibold))
                        }
                        if let why = status.tried ?? status.failure {
                            Text(why).font(.inter(Style.noteSize - 2)).lineLimit(2)
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.7))
                        }
                    }
                }
            }
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
            .padding(.horizontal, Style.rowInsetH)
            .padding(.top, Style.sectionGap)
        }
    }

    // MARK: Nothing to list (yet)

    @ViewBuilder
    private var emptyState: some View {
        if let error, sources.isEmpty {
            notice("exclamationmark.triangle", title: "Streams unavailable", detail: error)
        } else if let status = selectedStatus {
            switch status.phase {
            case .looking, .preparing:
                waiting("Asking \(status.name)…", detail: status.isPreparing ? status.detail : nil)
            case .notOnServer(let tried):
                notice("film.stack", title: "\(status.name) doesn't have this title", detail: tried)
            case .failed(let message):
                notice("wifi.exclamationmark", title: "\(status.name) didn't answer", detail: message)
            case .found:
                notice("play.slash", title: "No streams on \(status.name)", detail: nil)
            }
        } else if loading || statuses.contains(where: \.isWaiting) {
            waiting("Finding streams…", detail: asking)
        } else {
            notice("play.slash", title: "No streams found",
                   detail: statuses.count > 1 ? "None of your servers had a playable version of this title."
                                              : "Your server had no playable version of this title.")
        }
    }

    private var asking: String? {
        let names = statuses.map(\.name)
        return names.isEmpty ? nil : "Asking " + ListFormatter.localizedString(byJoining: names)
    }

    private func waiting(_ title: String, detail: String?) -> some View {
        VStack(spacing: Style.lineGap * 2) {
            ProgressView().controlSize(.large)
            Text(title).font(.inter(Style.noticeTitleSize, .semibold))
            if let detail {
                Text(detail).font(.inter(Style.noteSize))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Style.noticeTop)
        .mediaFocusAnchor()
    }

    private func notice(_ symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: Style.lineGap * 2) {
            Image(systemName: symbol)
                .font(.system(size: Style.noticeSymbolSize, weight: .semibold, design: .rounded))
                .opacity(0.5)
            Text(title).font(.inter(Style.noticeTitleSize, .semibold))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.inter(Style.noteSize))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                    .multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Style.noticeTop)
        .mediaFocusAnchor()
    }
}

/// The title's own wide picture behind the top of the list, fading into the
/// background well before the first row, so it sets the scene without
/// sitting behind anything that has to be read.
private struct MediaStreamBackdrop: View {
    let url: URL?

    var body: some View {
        Color.clear
            .frame(height: MediaStreamStyle.backdropHeight + MediaStreamStyle.backdropBleed)
            .frame(maxWidth: .infinity)
            .overlay {
                LineupArtView(url: url, width: MediaStreamStyle.backdropWidth) { image in
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
            .clipped()
            .overlay {
                LinearGradient(stops: [
                    .init(color: LineupStyle.background.opacity(0.45), location: 0),
                    .init(color: LineupStyle.background.opacity(0.78), location: 0.5),
                    .init(color: LineupStyle.background, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                LinearGradient(colors: [LineupStyle.background.opacity(0.7), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
            // Up into the margin above the list -- the television's overscan,
            // the phone's bar -- so the picture runs to the top edge rather
            // than stopping a band short of it.
            .padding(.top, -MediaStreamStyle.backdropBleed)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A tab in the stream list: its name, then how its search went.
private struct MediaStreamTab: View {
    enum Mark: Equatable {
        case count(Int)
        case looking
        case missing
        case failed
    }

    @Environment(\.isFocused) private var focused
    let title: String
    let mark: Mark
    let active: Bool
    /// The server's logo, ahead of its name.
    var brand: MediaServerBrand? = nil

    private typealias Style = MediaStreamStyle

    var body: some View {
        HStack(spacing: Style.tabInnerGap) {
            if let brand {
                MediaServerLogo(brand: brand).frame(width: Style.tabSize, height: Style.tabSize)
            }
            Text(title).font(.inter(Style.tabSize, .semibold)).lineLimit(1)
            markView
        }
        .padding(.horizontal, Style.tabPadH).padding(.vertical, Style.tabPadV)
        // The app's chips, on both: the accent filled when chosen, outlined
        // otherwise.
        .foregroundStyle(active ? LineupStyle.onHighlight : LineupStyle.highlight)
        .background(active ? LineupStyle.highlight : Color.clear, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? Color.clear : LineupStyle.highlight, lineWidth: 1.5))
        .opacity(quiet && !active ? 0.55 : 1)
        .lineupFocusLayer(focused && !active, in: Capsule())
        .scaleEffect(focused ? LineupStyle.controlLift : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }

    /// A place that found nothing stays a tab -- it says why when chosen --
    /// but steps back from the ones with streams.
    private var quiet: Bool { mark == .missing || mark == .failed }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .count(let count):
            Text("\(count)").font(.interDigits(Style.tabCountSize, .bold)).opacity(0.55)
        case .looking:
            ProgressView()
                .tint(active ? LineupStyle.onHighlight : LineupStyle.highlight)
                .scaleEffect(Style.tabSpinnerScale)
                .frame(width: Style.tabSpinner, height: Style.tabSpinner)
        case .missing:
            Text("—").font(.inter(Style.tabCountSize, .bold)).opacity(0.5)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Style.tabCountSize - 3, weight: .bold, design: .rounded)).opacity(0.6)
        }
    }
}

/// One stream, read the way a stream is chosen: its resolution and range on
/// the left, what it is in a line, the release under that, where it is from
/// under that, and its size on the right, where every row's lines up.
private struct MediaStreamRow: View {
    let source: MediaPlaybackSource

    private typealias Style = MediaStreamStyle

    var body: some View {
        HStack(alignment: .center, spacing: Style.rowGap) {
            tile
            VStack(alignment: .leading, spacing: Style.lineGap) {
                Text(summary)
                    .font(.inter(Style.summarySize, .semibold))
                    .lineLimit(Style.summaryLines)
                    .fixedSize(horizontal: false, vertical: true)
                Text(source.releaseName)
                    .font(.inter(Style.releaseSize))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
                    .lineLimit(1).truncationMode(.middle)
                #if !os(tvOS)
                // A phone is too narrow for a column of sizes beside the
                // text, so they are a line of their own.
                if let measures = measuresLine {
                    Text(measures)
                        .font(.interDigits(Style.rateSize, .semibold))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.8))
                }
                #endif
                origin
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            measures
            #endif
        }
        .padding(.horizontal, Style.rowInsetH).padding(.vertical, Style.rowInsetV)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: Style.rowRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Style.rowRadius, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
        #else
        // A panel of its own, as every card on the phone is.
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: Style.rowRadius, style: .continuous))
        #endif
        .foregroundStyle(LineupStyle.lightPurple)
        .accessibilityElement(children: .combine)
    }

    /// Resolution, large, with the dynamic range under it.
    private var tile: some View {
        VStack(spacing: Style.tileGap) {
            Text(source.quality ?? (source.directURL != nil ? "VOD" : "SD"))
                .font(.interDigits(Style.tileSize, .heavy))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let range = dynamicRange {
                Text(range)
                    .font(.inter(Style.tileRangeSize, .heavy)).tracking(0.6)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .opacity(0.72)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: Style.tileWidth, height: Style.tileHeight)
        .background(LineupStyle.lightPurple.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Style.tileRadius, style: .continuous))
    }

    private var dynamicRange: String? {
        let tags = source.dynamicRangeTags
        return tags.isEmpty ? nil : tags.joined(separator: " · ")
    }

    /// What it is, in one line: where it was mastered from, how it is
    /// encoded, how it sounds.
    private var summary: String {
        var parts: [String] = []
        if let tag = source.sourceTag { parts.append(tag) }
        if let codec = source.videoCodec {
            parts.append(source.bitDepth == "10-bit" ? codec + " 10-bit" : codec)
        }
        let audio = [source.audioCodec, source.audioChannels].compactMap { $0 }.joined(separator: " ")
        if source.hasAtmos {
            parts.append(audio.isEmpty ? "Atmos" : audio + " Atmos")
        } else if !audio.isEmpty {
            parts.append(audio)
        }
        if !parts.isEmpty { return parts.joined(separator: Style.separator) }
        if source.directURL != nil { return "Your IPTV provider's copy" }
        return source.containerLabel.map { $0 + " file" } ?? "Stream"
    }

    /// What a stream is chosen by beyond what it is: the server's ranking,
    /// which the list is in order of, and whether it plays at once. Its
    /// server is the section it is listed under. The add-on and indexer that
    /// found it are left out: they say nothing about which to pick.
    @ViewBuilder
    private var origin: some View {
        let rank = source.rankLabel
        if rank != nil || source.isInstant {
            HStack(spacing: Style.markGap) {
                if let rank {
                    Text(rank).tracking(1.2)
                        .font(.interDigits(Style.markSize + 1, .heavy))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.9))
                        .fixedSize()
                }
                if source.isInstant {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                        Text("INSTANT").tracking(1.2)
                    }
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.85))
                    .fixedSize()
                }
            }
            .font(.inter(Style.markSize, .heavy))
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
        }
    }

    private var measuresLine: String? {
        let parts = [source.formattedSize, source.formattedBitrate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: Style.separator)
    }

    /// Size over bitrate, right-aligned, so the column of them can be read
    /// down the list.
    @ViewBuilder
    private var measures: some View {
        let size = source.formattedSize
        let rate = source.formattedBitrate
        if size != nil || rate != nil {
            VStack(alignment: .trailing, spacing: Style.lineGap) {
                if let size {
                    Text(size).font(.interDigits(Style.sizeSize, .semibold))
                }
                if let rate {
                    Text(rate).font(.interDigits(Style.rateSize)).opacity(0.55)
                }
            }
            .lineLimit(1)
            .frame(width: Style.measureWidth, alignment: .trailing)
        }
    }
}

/// The stream list's measurements, one set per platform.
private enum MediaStreamStyle {
    #if os(tvOS)
    static let boardWidth: CGFloat = 1480
    static let sideInset: CGFloat = 0
    static let bottomInset: CGFloat = 60
    static let backdropHeight: CGFloat = 640
    static let backdropBleed: CGFloat = 90
    static let backdropWidth: CGFloat = 1920
    static let headerTop: CGFloat = 36
    static let headerBottom: CGFloat = 30
    static let headerGap: CGFloat = 8
    static let eyebrowSize: CGFloat = 15
    static var caption: Color { LineupStyle.lightPurple.opacity(0.55) }
    static var sectionCaption: Color { LineupStyle.lightPurple.opacity(0.5) }
    static let eyebrowTracking: CGFloat = 2.2
    static let titleSize: CGFloat = 54
    static let subtitleSize: CGFloat = 24
    static let tabSize: CGFloat = 22
    static let tabCountSize: CGFloat = 19
    static let tabPadH: CGFloat = 22
    static let tabPadV: CGFloat = 11
    static let tabGap: CGFloat = 14
    static let tabInnerGap: CGFloat = 10
    static let tabSpinner: CGFloat = 22
    static let tabSpinnerScale: CGFloat = 0.5
    static let tabLift: CGFloat = 10
    static let tabsBottom: CGFloat = 22
    static let sectionSize: CGFloat = 15
    static let sectionGap: CGFloat = 34
    static let rowSpacing: CGFloat = 12
    static let rowRadius: CGFloat = 18
    static let rowInsetH: CGFloat = 22
    static let rowInsetV: CGFloat = 18
    static let rowGap: CGFloat = 24
    static let lineGap: CGFloat = 6
    static let tileWidth: CGFloat = 118
    static let tileHeight: CGFloat = 84
    static let tileRadius: CGFloat = 12
    static let tileGap: CGFloat = 2
    static let tileSize: CGFloat = 30
    static let tileRangeSize: CGFloat = 13
    static let summarySize: CGFloat = 25
    static let releaseSize: CGFloat = 19
    static let markSize: CGFloat = 14
    static let markGap: CGFloat = 12
    static let sizeSize: CGFloat = 25
    static let rateSize: CGFloat = 18
    static let measureWidth: CGFloat = 150
    static let noteSize: CGFloat = 20
    static let noticeTitleSize: CGFloat = 28
    static let noticeSymbolSize: CGFloat = 44
    static let noticeTop: CGFloat = 70
    static let separator = "  ·  "
    static let summaryLines = 1
    #else
    static let boardWidth: CGFloat = .infinity
    static let sideInset: CGFloat = 16
    static let bottomInset: CGFloat = 28
    static let backdropHeight: CGFloat = 300
    static let backdropBleed: CGFloat = 240
    static let backdropWidth: CGFloat = 900
    static let headerTop: CGFloat = 8
    static let headerBottom: CGFloat = 16
    static let headerGap: CGFloat = 4
    static let eyebrowSize: CGFloat = 13
    static var caption: Color { LineupPanelStyle.caption }
    static var sectionCaption: Color { LineupPanelStyle.caption }
    static let eyebrowTracking: CGFloat = 0.4
    static let titleSize: CGFloat = 26
    static let subtitleSize: CGFloat = 14
    static let tabSize: CGFloat = 14
    static let tabCountSize: CGFloat = 12
    static let tabPadH: CGFloat = 14
    static let tabPadV: CGFloat = 8
    static let tabGap: CGFloat = 8
    static let tabInnerGap: CGFloat = 6
    static let tabSpinner: CGFloat = 14
    static let tabSpinnerScale: CGFloat = 0.6
    static let tabLift: CGFloat = 2
    static let tabsBottom: CGFloat = 14
    static let sectionSize: CGFloat = 14
    static let sectionGap: CGFloat = 22
    static let rowSpacing: CGFloat = 8
    static let rowRadius: CGFloat = 20
    static let rowInsetH: CGFloat = 12
    static let rowInsetV: CGFloat = 12
    static let rowGap: CGFloat = 12
    static let lineGap: CGFloat = 3
    static let tileWidth: CGFloat = 58
    static let tileHeight: CGFloat = 50
    static let tileRadius: CGFloat = 10
    static let tileGap: CGFloat = 1
    static let tileSize: CGFloat = 16
    static let tileRangeSize: CGFloat = 8
    static let summarySize: CGFloat = 15
    static let releaseSize: CGFloat = 12
    static let markSize: CGFloat = 9
    static let markGap: CGFloat = 8
    static let sizeSize: CGFloat = 14
    static let rateSize: CGFloat = 11
    static let measureWidth: CGFloat = 70
    static let noteSize: CGFloat = 13
    static let noticeTitleSize: CGFloat = 17
    static let noticeSymbolSize: CGFloat = 30
    static let noticeTop: CGFloat = 40
    static let separator = " · "
    static let summaryLines = 2
    #endif
}

/// A stream carries anywhere from two to seven badges. One row of them either
/// clips the last few or squeezes every badge until none of them read, so they
/// wrap onto as many lines as the width needs.
private struct BadgeFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = wrap(subviews, within: proposal.width ?? .infinity)
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? (lines.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in wrap(subviews, within: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func wrap(_ subviews: Subviews, within width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if extended > width, !line.indices.isEmpty {
                lines.append(line)
                line = Line(indices: [index], width: size.width, height: size.height)
            } else {
                line.indices.append(index)
                line.width = extended
                line.height = max(line.height, size.height)
            }
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

/// IMDb, TMDB and Rotten Tomatoes as dark chips, each source named in its
/// own colour the way the sites' own badges are.
struct MediaRatingChips: View {
    let ratings: MediaRatings

    private typealias Metrics = MediaRatingMetrics

    var body: some View {
        HStack(spacing: Metrics.gap) {
            if let imdb = ratings.imdb {
                chip("Rating-IMDb", spoken: "IMDb", value: String(format: "%.1f", imdb))
            }
            if let tmdb = ratings.tmdb {
                chip("Rating-TMDB", spoken: "TMDB", value: String(format: "%.1f", tmdb))
            }
            if let tomatoes = ratings.rottenTomatoes {
                chip("Rating-RT", spoken: "Rotten Tomatoes", value: "\(tomatoes)%")
            }
        }
        .fixedSize()
    }

    /// Each site by its own mark rather than its name in letters: IMDb's
    /// yellow badge, TMDB's square mark and the Tomatometer's tomato, all
    /// the same height.
    private func chip(_ logo: String, spoken: String, value: String) -> some View {
        HStack(spacing: Metrics.inner) {
            Image(logo)
                .resizable()
                .scaledToFit()
                .frame(height: Metrics.logo)
                .accessibilityHidden(true)
            Text(value)
                .font(.interDigits(Metrics.valueSize, .bold))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, Metrics.padding)
        .frame(height: Metrics.height)
        .background(Metrics.fill, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spoken) \(value)")
    }
}

private enum MediaRatingMetrics {
    static let fill = Color(red: 0.15, green: 0.16, blue: 0.19).opacity(0.9)
    #if os(tvOS)
    static let height: CGFloat = 42
    static let padding: CGFloat = 14
    static let gap: CGFloat = 12
    static let inner: CGFloat = 11
    static let logo: CGFloat = 26
    static let valueSize: CGFloat = 22
    static let radius: CGFloat = 10
    #else
    static let height: CGFloat = 30
    static let padding: CGFloat = 9
    static let gap: CGFloat = 8
    static let inner: CGFloat = 7
    static let logo: CGFloat = 18
    static let valueSize: CGFloat = 15
    static let radius: CGFloat = 8
    #endif
}

/// An episode's primary image is a 16:9 still and a movie's is a portrait poster.
/// Choosing per item is what left a shelf ragged, so a screen picks one shape
/// from what it is showing and every card on it is cut to that shape.
enum MediaArtShape {
    case poster
    case still

    var ratio: CGFloat { self == .poster ? 2 / 3 : 16 / 9 }

    var isPoster: Bool { self == .poster }

    static func forItems(_ items: [MediaItem]) -> MediaArtShape {
        if items.isEmpty { return .poster }
        return items.contains(where: { $0.type != "Episode" }) ? .poster : .still
    }
}

struct MediaItemCard: View {
    @EnvironmentObject private var media: MediaLibrary
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var artworkFocused
    #endif
    let item: MediaItem
    var shape: MediaArtShape = .poster

    var body: some View {
        let playback = playbackPresentation
        return VStack(alignment: .leading, spacing: 10) {
            // A resizable image keeps its own pixel size as its ideal size, so an
            // aspect box built around the art still took the shape of whatever the
            // server sent: shelves stayed ragged, and a 16:9 episode still grew
            // past its cell and painted over the cards beside it. The box is a
            // clear rectangle with no size of its own, sized from the width the
            // grid offers, and the art hangs off it as an overlay where filling
            // and cropping cannot reach the layout.
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(shape.ratio, contentMode: .fit)
                .overlay {
                    ZStack {
                        if let service = StreamingService.service(for: item) {
                            // A service's poster is its own mark, drawn here
                            // rather than fetched.
                            StreamingServicePoster(service: service)
                        } else {
                            LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                            LineupArtView(url: artworkURL, width: artWidth) { loaded in
                                if let image = loaded { image.resizable().scaledToFill() }
                                else { Image(systemName: item.isFolder ? "rectangle.stack.fill" : "film.fill").font(.inter(.largeTitle)) }
                            }
                        }
                    }
                    // Where the viewer is, on the art rather than under it: a
                    // row's titles then sit on one line whether or not a card
                    // has been started.
                    .overlay(alignment: .bottom) {
                        if let playback {
                            MediaArtworkProgress(playback: playback)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .lineupFocusLayer(artworkIsFocused, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                // An episode the server does not have yet: the day it airs.
                .overlay(alignment: .topLeading) {
                    if let label = item.upcomingLabel {
                        Text(label)
                            .font(.inter(upcomingLabelSize, .heavy)).tracking(LineupPanelStyle.headerTracking)
                            .foregroundStyle(LineupStyle.text)
                            .padding(.horizontal, upcomingLabelSize * 0.8).padding(.vertical, upcomingLabelSize * 0.4)
                            .background(LineupPanelStyle.fill.opacity(0.92), in: Capsule())
                            .padding(upcomingLabelSize * 0.8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if playback?.watched == true {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(LineupStyle.background)
                            .frame(width: 25, height: 25)
                            .background(LineupStyle.lightPurple, in: Circle())
                            .padding(9)
                    }
                }
            // Two lines are held whether or not the title needs them, so the line
            // under it lands on the same baseline across a row.
            Text(item.name).font(titleFont).lineLimit(2, reservesSpace: true)
                #if os(tvOS)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                #endif
            #if !os(tvOS)
            // The television shows a poster and its title and nothing more:
            // "MOVIE · 2026" under every card was clutter a viewer reads past.
            // The phone keeps the line on every card, so a row stays even.
            HStack(spacing: 7) {
                if StreamingService.service(for: item) != nil {
                    Text(item.childCount == 1 ? "1 TITLE" : "\(item.childCount ?? 0) TITLES")
                } else {
                    Text(item.type.uppercased())
                    if let year = item.productionYear { Text("· \(String(year))") }
                    if let count = item.childCount { Text("· \(count)") }
                }
            }
            .font(.inter(.caption2, .medium))
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.58))
            #endif
        }
        .foregroundStyle(LineupStyle.lightPurple)
    }

    private var artworkIsFocused: Bool {
        #if os(tvOS)
        artworkFocused
        #else
        false
        #endif
    }


    /// A show's poster -- or an episode's, standing in for its show --
    /// counts episodes; anything else counts time.
    private var playbackPresentation: MediaCardPlayback? {
        media.cardPlayback(for: item, asShow: item.isSeries || (shape.isPoster && item.type == "Episode"))
    }

    /// The widest this card is ever drawn -- the top of the grid's adaptive
    /// range, which is wider than the fixed width a shelf gives it. One size
    /// per shape means a title scrolled past in a shelf and met again in a
    /// grid is the same cached picture both times.
    private var artWidth: CGFloat { Self.artWidth(shape) }
    private var artworkURL: URL? {
        Self.artworkURL(for: item, shape: shape, in: media)
    }

    /// The card's art, address and size, worked out without a card, so a
    /// shelf can fetch it before the card is drawn and the card finds it
    /// made (`LineupArt.prefetch`).
    static func art(for item: MediaItem, shape: MediaArtShape, in media: MediaLibrary) -> (url: URL?, pixels: Int) {
        (artworkURL(for: item, shape: shape, in: media), LineupArt.pixels(for: artWidth(shape)))
    }

    private static func artWidth(_ shape: MediaArtShape) -> CGFloat {
        #if os(tvOS)
        shape == .poster ? 310 : 460
        #else
        shape == .poster ? 210 : 300
        #endif
    }

    private static func artworkURL(for item: MediaItem, shape: MediaArtShape, in media: MediaLibrary) -> URL? {
        let width = Int(artWidth(shape))
        if shape.isPoster, item.type == "Episode" {
            return media.seriesPosterURL(for: item, width: width)
                ?? media.imageURL(for: item, width: width)
        }
        return media.imageURL(for: item, width: width)
    }
    private var cardRadius: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }
    private var upcomingLabelSize: CGFloat {
        #if os(tvOS)
        16
        #else
        10
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        // tvOS's semantic headline size is designed for page copy and made
        // shelf labels compete with the poster itself. A compact lockup size
        // stays readable from the couch, keeps long names to two clean lines,
        // and lets more of the next catalog remain visible.
        .inter(22, .semibold)
        #else
        .inter(.subheadline, .semibold)
        #endif
    }
}

/// Where a viewer is in a title, laid across the foot of its artwork: the
/// words, the track under them, and a shade behind both so they read over
/// light art and dark alike.
///
/// It used to sit between the artwork and the title, which pushed that one
/// card's title a line below its neighbours'. On the art it takes no height
/// of the card's own, so every title in a row lines up.
/// Where the viewer is, on the art: a play mark, a bar and a few words over a
/// dark fall at the foot of the picture -- "8 of 16" for a show, the time
/// left for a film -- and, for a show, the episode under way as a thin bar
/// along the card's bottom edge.
private struct MediaArtworkProgress: View {
    let playback: MediaCardPlayback

    var body: some View {
        VStack(spacing: playback.episodeFraction == nil ? 0 : rowToEdge) {
            HStack(spacing: gap) {
                Image(systemName: "play.fill")
                    .font(.system(size: glyph, weight: .bold, design: .rounded))
                MediaProgressTrack(fraction: playback.fraction, thickness: track)
                Text(playback.label)
                    .font(.interDigits(labelSize, .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(.horizontal, inset)
            .padding(.bottom, playback.episodeFraction == nil ? inset : 0)
            if let episode = playback.episodeFraction {
                // Flush with the card's foot, rounded by its corners.
                MediaProgressTrack(fraction: episode, thickness: edge, rounded: false, rest: 0.28)
            }
        }
        .padding(.top, inset * 3.2)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.5), location: 0.4),
                .init(color: .black.opacity(0.84), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(playback.spoken)
    }

    #if os(tvOS)
    private var glyph: CGFloat { 17 }
    private var track: CGFloat { 9 }
    private var labelSize: CGFloat { 19 }
    private var gap: CGFloat { 12 }
    private var inset: CGFloat { 14 }
    private var edge: CGFloat { 6 }
    private var rowToEdge: CGFloat { 12 }
    #else
    private var glyph: CGFloat { 10 }
    private var track: CGFloat { 5 }
    private var labelSize: CGFloat { 12 }
    private var gap: CGFloat { 7 }
    private var inset: CGFloat { 9 }
    private var edge: CGFloat { 3 }
    private var rowToEdge: CGFloat { 8 }
    #endif
}

/// The app's progress bar on the art: the accent on a grey track. Along the
/// card's foot it runs flush, squared off and rounded only by the card's own
/// corners.
private struct MediaProgressTrack: View {
    let fraction: Double
    let thickness: CGFloat
    var rounded = true
    var rest = 0.3

    var body: some View {
        if rounded {
            LineupProgressBar(value: fraction, height: thickness, track: .white.opacity(rest))
        } else {
            GeometryReader { proxy in
                let filled = proxy.size.width * CGFloat(min(max(fraction, 0), 1))
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(rest))
                    Rectangle().fill(LineupStyle.highlight).frame(width: filled)
                }
            }
            .frame(height: thickness)
        }
    }
}

/// Adding a media server: its kind chosen by logo, and that kind's own way
/// in beside it.
///
/// Choosing is moving. On the television, the server whose logo has focus is
/// the one being added, and its sign-in is already there below it; on the
/// phone, the sign-ins sit side by side and a swipe moves between them as a
/// tap on a logo does.
///
/// All three sign-ins are built once, when the screen opens, and are only
/// ever shown and hidden after that. Building one afresh on every move, text
/// fields and all, is what made moving between them stutter.
struct MediaServerSetupView: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var software: MediaServerBrand = .jellyfin
    /// What has been typed for each kind, kept apart, so moving across to
    /// look at another does not carry one server's address into another's.
    @State private var forms: [MediaServerBrand: MediaServerSignIn] = [:]
    #if !os(tvOS)
    @State private var page: MediaServerBrand? = .jellyfin
    /// Held, not observed: a swipe moves the marker under the logos on every
    /// frame, and only the logos should redraw for it.
    @State private var swipe = MediaServerSwipe()
    #endif

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                PageTitle(eyebrow: "Settings", title: "Add Media Server",
                          detail: "Move across to your server. Its sign-in follows.")
                MediaServerPicker(selection: choice)
                // Laid over one another at one height, so the page never
                // shifts as they change; the one shown fades and slides in
                // from the side its logo is on.
                MediaServerPanelStack {
                    ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                        let shown = brand == software
                        panel(for: brand)
                            .opacity(shown ? 1 : 0)
                            .offset(x: shown ? 0 : (order(of: brand) < order(of: software) ? -36 : 36))
                            // A hidden sign-in never takes focus.
                            .disabled(!shown)
                            .accessibilityHidden(!shown)
                    }
                }
                // Down from any logo lands here, the Plex one at the far
                // right included, whatever sits directly beneath it.
                .focusSection()
                if let error = media.errorMessage {
                    Text(error).font(.inter(.callout)).foregroundStyle(LineupStyle.live)
                }
                // A television draws no navigation bar, so this screen's way
                // out is a button of its own.
                Button("Cancel", role: .cancel) { dismiss() }
                    .lineupButtonStyle()
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 56)
        }
        .background(LineupStyle.background.ignoresSafeArea())
        .disabled(media.isAddingServer)
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MediaServerPicker(selection: choice, swipe: swipe)
                        .padding(.horizontal, 16)
                    // The sign-ins side by side, one to a page, all of one
                    // height: a swipe moves between servers as a tap on a
                    // logo does, and the marker under the logos follows the
                    // finger.
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                                panel(for: brand)
                                    .padding(.horizontal, 16)
                                    .containerRelativeFrame(.horizontal)
                            }
                        }
                        .scrollTargetLayout()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $page)
                    .scrollIndicators(.hidden)
                    .modifier(MediaServerPagerTracking(swipe: swipe))
                    if let error = media.errorMessage {
                        Text(error).font(.inter(.footnote)).foregroundStyle(LineupStyle.live)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LineupStyle.background)
            .navigationTitle("Add Media Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .disabled(media.isAddingServer)
            .onChange(of: page) { _, brand in
                guard let brand, brand != software else { return }
                clearError()
                software = brand
                // Without the pager's own position to follow, the marker
                // glides to the page it settled on.
                if #unavailable(iOS 18) {
                    withAnimation(.smooth(duration: 0.3)) { swipe.progress = CGFloat(order(of: brand)) }
                }
            }
        }
        #endif
    }

    /// The server being added, chosen from the logos.
    private var choice: Binding<MediaServerBrand> {
        Binding {
            software
        } set: { brand in
            guard brand != software else { return }
            clearError()
            #if os(tvOS)
            withAnimation(.smooth(duration: 0.3)) { software = brand }
            #else
            software = brand
            withAnimation(.smooth(duration: 0.35)) { page = brand }
            #endif
        }
    }

    /// One server's failure is not news on the next one's sign-in. Only a
    /// message that is there is cleared: every write to the Library, even of
    /// what it already holds, redraws everything that watches it, the whole
    /// Library behind this screen included.
    private func clearError() {
        if media.errorMessage != nil { media.errorMessage = nil }
    }

    private func order(of brand: MediaServerBrand) -> Int {
        MediaServerBrand.allCases.firstIndex(of: brand) ?? 0
    }

    @ViewBuilder private func panel(for brand: MediaServerBrand) -> some View {
        if brand == .plex {
            PlexLinkPanel(onAdded: { dismiss() })
        } else {
            MediaServerSignInPanel(brand: brand, form: form(for: brand)) { sign in
                Task {
                    if await media.addServer(name: sign.name, serverURL: sign.server, username: sign.username,
                                             password: sign.password, software: brand) { dismiss() }
                }
            }
        }
    }

    private func form(for brand: MediaServerBrand) -> Binding<MediaServerSignIn> {
        Binding { forms[brand] ?? MediaServerSignIn() } set: { forms[brand] = $0 }
    }
}

/// What a Jellyfin or Emby sign-in has been given so far.
struct MediaServerSignIn: Equatable {
    var name = ""
    var server = ""
    var username = ""
    var password = ""

    /// A password is not required. Jellyfin and Emby both allow passwordless
    /// users, and some ship that way until an operator sets one.
    var isComplete: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Every sign-in in one place, each given the height of the tallest, so the
/// card stays the same size whichever is shown.
private struct MediaServerPanelStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

#if !os(tvOS)
/// How far across the sign-ins the phone's pager sits, in pages.
final class MediaServerSwipe: ObservableObject {
    @Published var progress: CGFloat = 0
}

/// Keeps the marker under the logos where the pager is, frame by frame, as a
/// finger or a tap moves it. The pager says where it is itself: a reading
/// taken from inside its pages was never passed on, which left the marker on
/// the first logo.
private struct MediaServerPagerTracking: ViewModifier {
    let swipe: MediaServerSwipe

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                (geometry.contentOffset.x + geometry.contentInsets.leading) / max(geometry.containerSize.width, 1)
            } action: { _, progress in
                swipe.progress = progress
            }
        } else {
            content
        }
    }
}
#endif

/// The three kinds of server, by their logos. On the television the one with
/// focus is the one chosen, so moving across them is choosing.
private struct MediaServerPicker: View {
    @Binding var selection: MediaServerBrand
    #if os(tvOS)
    @FocusState private var focused: MediaServerBrand?
    #else
    @ObservedObject var swipe: MediaServerSwipe
    #endif

    var body: some View {
        #if os(tvOS)
        HStack(spacing: gap) {
            ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                let chosen = selection == brand
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                tile(brand, chosen: chosen)
                    .background(chosen ? LineupStyle.focused : LineupStyle.raised, in: shape)
                    .overlay(shape.strokeBorder(chosen ? LineupStyle.text.opacity(0.6) : LineupStyle.line,
                                                lineWidth: chosen ? 1.5 : 0.5))
                    .lineupFocusLayer(focused == brand, in: shape.inset(by: -6))
                    .focusable()
                    .focused($focused, equals: brand)
                    .focusEffectDisabled()
                    .onTapGesture { selection = brand }
                    .scaleEffect(focused == brand ? LineupStyle.controlLift : 1)
                    .lineupShadow(.lifted, on: focused == brand)
                    .zIndex(focused == brand ? 1 : 0)
                    .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused == brand)
            }
        }
        // Coming back up from a sign-in returns to the logo it belongs to,
        // not to whichever logo happens to sit above the button just left.
        .defaultFocus($focused, selection, priority: .userInitiated)
        .focusSection()
        .onChange(of: focused) { _, brand in
            if let brand { selection = brand }
        }
        #else
        HStack(spacing: gap) {
            ForEach(MediaServerBrand.allCases, id: \.self) { brand in
                Button { selection = brand } label: { tile(brand, chosen: selection == brand) }
                    .lineupFlatButton()
            }
        }
        .background { marker }
        #endif
    }

    #if !os(tvOS)
    /// The tiles' wells, and the chosen fill gliding across them as the
    /// sign-ins below are swiped.
    private var marker: some View {
        GeometryReader { row in
            let count = CGFloat(MediaServerBrand.allCases.count)
            let width = (row.size.width - gap * (count - 1)) / count
            let position = min(max(swipe.progress, 0), count - 1)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack(alignment: .leading) {
                HStack(spacing: gap) {
                    ForEach(MediaServerBrand.allCases, id: \.self) { _ in
                        shape.fill(LineupStyle.raised)
                            .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 0.5))
                    }
                }
                shape.fill(LineupStyle.focused)
                    .overlay(shape.strokeBorder(LineupStyle.text.opacity(0.6), lineWidth: 1.5))
                    .frame(width: width)
                    .offset(x: (width + gap) * position)
            }
        }
    }
    #endif

    private func tile(_ brand: MediaServerBrand, chosen: Bool) -> some View {
        VStack(spacing: labelGap) {
            MediaServerLogo(brand: brand).frame(width: logo, height: logo)
            Text(brand.name).font(.inter(labelSize, .semibold))
                .foregroundStyle(chosen ? LineupStyle.text : LineupStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, padding)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    #if os(tvOS)
    private var gap: CGFloat { 28 }
    private var logo: CGFloat { 72 }
    private var padding: CGFloat { 26 }
    private var radius: CGFloat { 20 }
    private var labelGap: CGFloat { 12 }
    private var labelSize: CGFloat { 24 }
    #else
    private var gap: CGFloat { 10 }
    private var logo: CGFloat { 34 }
    private var padding: CGFloat { 12 }
    private var radius: CGFloat { 14 }
    private var labelGap: CGFloat { 8 }
    private var labelSize: CGFloat { 15 }
    #endif
}

/// A server's own sign-in, under its logo and name.
private struct MediaServerPanel<Content: View>: View {
    let brand: MediaServerBrand
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: headerGap) {
                MediaServerLogo(brand: brand).frame(width: logo, height: logo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.inter(titleSize, .semibold)).foregroundStyle(LineupStyle.text)
                    Text(brand.signInNote).font(.inter(noteSize)).foregroundStyle(LineupStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(inset)
        // As tall as it is given: beside or behind the other sign-ins, each
        // card takes the tallest one's height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupStyle.surface, in: shape)
        .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 0.5))
    }

    #if os(tvOS)
    private var radius: CGFloat { 26 }
    private var spacing: CGFloat { 30 }
    private var headerGap: CGFloat { 20 }
    private var logo: CGFloat { 56 }
    private var titleSize: CGFloat { 32 }
    private var noteSize: CGFloat { 22 }
    private var inset: CGFloat { 36 }
    #else
    private var radius: CGFloat { 18 }
    private var spacing: CGFloat { 18 }
    private var headerGap: CGFloat { 12 }
    private var logo: CGFloat { 36 }
    private var titleSize: CGFloat { 18 }
    private var noteSize: CGFloat { 13 }
    private var inset: CGFloat { 16 }
    #endif
}

/// Jellyfin's or Emby's sign-in: where the server is, and whose account.
private struct MediaServerSignInPanel: View {
    @EnvironmentObject private var media: MediaLibrary
    let brand: MediaServerBrand
    @Binding var form: MediaServerSignIn
    let connect: (MediaServerSignIn) -> Void

    var body: some View {
        MediaServerPanel(brand: brand, title: "Sign in to \(brand.name)") {
            fields
                // A capitalised host or an autocorrected one is not the
                // address anybody meant to type, and on a television, where
                // every character costs a click, it is not obvious what went
                // wrong either.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                connect(form)
            } label: {
                Text(media.isAddingServer ? "Connecting…" : "Connect")
                    #if !os(tvOS)
                    .frame(maxWidth: .infinity)
                    #endif
            }
            .lineupButtonStyle()
            .disabled(media.isAddingServer || !form.isComplete)
            Text(footer)
                .font(.inter(footerSize)).foregroundStyle(LineupStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var fields: some View {
        #if os(tvOS)
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 22) {
            GridRow {
                MediaServerField(label: "Server address", prompt: "192.168.1.50:8096", text: $form.server, kind: .address)
                MediaServerField(label: "Display name", prompt: "Optional", text: $form.name)
            }
            GridRow {
                MediaServerField(label: "Username", prompt: "Username", text: $form.username, kind: .username)
                MediaServerField(label: "Password", prompt: "Optional", text: $form.password, kind: .password)
            }
        }
        #else
        VStack(spacing: 0) {
            MediaServerField(label: "Address", prompt: "192.168.1.50:8096", text: $form.server, kind: .address)
            Divider().overlay(LineupStyle.line).padding(.leading, 14)
            MediaServerField(label: "Name", prompt: "Optional", text: $form.name)
            Divider().overlay(LineupStyle.line).padding(.leading, 14)
            MediaServerField(label: "Username", prompt: "Required", text: $form.username, kind: .username)
            Divider().overlay(LineupStyle.line).padding(.leading, 14)
            MediaServerField(label: "Password", prompt: "Optional", text: $form.password, kind: .password)
        }
        .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #endif
    }

    private var footer: String {
        "The host and port is enough, as the server's web app opens on. Leave the password blank for a user that has none. Sign-ins are kept in this device's Keychain, and every server you add feeds the Library together."
    }

    #if os(tvOS)
    private var footerSize: CGFloat { 20 }
    #else
    private var footerSize: CGFloat { 12 }
    #endif
}

/// One labelled field of a sign-in.
private struct MediaServerField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var kind: Kind = .plain

    enum Kind { case plain, address, username, password }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.inter(20, .semibold)).foregroundStyle(LineupStyle.secondary)
            input
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        HStack(spacing: 12) {
            Text(label).font(.inter(.subheadline)).foregroundStyle(LineupStyle.secondary)
                .frame(width: 84, alignment: .leading)
            input
                .font(.inter(.subheadline))
                .foregroundStyle(LineupStyle.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        #endif
    }

    @ViewBuilder private var input: some View {
        switch kind {
        case .password:
            SecureField(label, text: $text, prompt: Text(prompt))
                #if !os(tvOS)
                .textContentType(.password)
                #endif
        case .address:
            TextField(label, text: $text, prompt: Text(prompt))
                #if !os(tvOS)
                .keyboardType(.URL)
                .textContentType(.URL)
                #endif
        case .username:
            TextField(label, text: $text, prompt: Text(prompt))
                #if !os(tvOS)
                .textContentType(.username)
                #endif
        case .plain:
            TextField(label, text: $text, prompt: Text(prompt))
        }
    }
}

/// Linking a Plex account, Plex's own way: a short code entered at
/// plex.tv/link, then the account's servers to choose from.
///
/// No password passes through Lineup. The account's token comes back to the
/// device that asked for the code, and each server's own token with it.
private struct PlexLinkPanel: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.openURL) private var openURL
    let onAdded: () -> Void

    private enum Step {
        case start
        case waiting(code: String)
        case finding
        case choosing([PlexAccount.Server])
        case failed(String)
    }

    @State private var step: Step = .start
    @State private var accountName = "Plex"
    @State private var linking: Task<Void, Never>?

    var body: some View {
        MediaServerPanel(brand: .plex, title: "Link your Plex account") {
            switch step {
            case .start:
                Text("You'll get a short code to enter at plex.tv/link on any phone or computer. Lineup never sees your Plex password.")
                    .font(.inter(bodySize)).foregroundStyle(LineupStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { link() } label: { wide("Link Plex Account") }
                    .lineupButtonStyle()
            case .waiting(let code):
                VStack(alignment: .leading, spacing: 14) {
                    Text("Go to **plex.tv/link** and enter this code:")
                        .font(.inter(bodySize)).foregroundStyle(LineupStyle.secondary)
                    Text(code)
                        .font(.interDigits(codeSize, .heavy)).tracking(codeSize * 0.22)
                        .foregroundStyle(LineupStyle.text)
                        .padding(.horizontal, codeSize * 0.6).padding(.vertical, codeSize * 0.3)
                        .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Waiting for Plex…").font(.inter(captionSize)).foregroundStyle(LineupStyle.secondary)
                    }
                }
                #if !os(tvOS)
                Button { openURL(URL(string: "https://plex.tv/link")!) } label: { wide("Open plex.tv/link") }
                    .lineupButtonStyle()
                #endif
            case .finding:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding your Plex servers…").font(.inter(bodySize)).foregroundStyle(LineupStyle.secondary)
                }
            case .choosing(let servers):
                Text("Choose the server to add.")
                    .font(.inter(bodySize)).foregroundStyle(LineupStyle.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(servers) { server in
                        Button { add(server) } label: {
                            HStack(spacing: 12) {
                                MediaServerLogo(brand: .plex).frame(width: rowLogo, height: rowLogo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).font(.inter(bodySize, .semibold)).foregroundStyle(LineupStyle.text)
                                    Text(server.owned == false ? "Shared with you" : "Your server")
                                        .font(.inter(captionSize)).foregroundStyle(LineupStyle.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .lineupButtonStyle()
                    }
                }
            case .failed(let message):
                Text(message).font(.inter(bodySize)).foregroundStyle(LineupStyle.live)
                Button { link() } label: { wide("Try Again") }
                    .lineupButtonStyle()
            }
        }
        .onDisappear { linking?.cancel() }
    }

    private func wide(_ title: String) -> some View {
        Text(title)
            #if !os(tvOS)
            .frame(maxWidth: .infinity)
            #endif
    }

    private func link() {
        linking?.cancel()
        linking = Task { @MainActor in
            do {
                let clientID = media.plexClientID
                let pin = try await PlexAccount.requestPin(clientID: clientID)
                withAnimation(.smooth) { step = .waiting(code: pin.code) }
                // A code lasts about a quarter of an hour. A check that fails
                // on the way is asked again: one dropped request is no reason
                // to send the viewer back for a new code.
                let deadline = Date().addingTimeInterval(15 * 60)
                var token: String?
                while token == nil, Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    token = (try? await PlexAccount.checkPin(pin.id, clientID: clientID))?.authToken
                }
                guard let token else {
                    step = .failed("That code has expired. Get a new one and try again.")
                    return
                }
                withAnimation(.smooth) { step = .finding }
                accountName = (try? await PlexAccount.user(token: token, clientID: clientID))?.displayName ?? "Plex"
                let servers = try await PlexAccount.servers(token: token, clientID: clientID)
                guard !servers.isEmpty else {
                    step = .failed("This Plex account has no servers to add.")
                    return
                }
                // One server is the one meant; several are a choice.
                if servers.count == 1 {
                    add(servers[0])
                } else {
                    withAnimation(.smooth) { step = .choosing(servers) }
                }
            } catch is CancellationError {
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    private func add(_ server: PlexAccount.Server) {
        Task { @MainActor in
            if await media.addPlexServer(server, accountName: accountName) { onAdded() }
        }
    }

    #if os(tvOS)
    private var bodySize: CGFloat { 24 }
    private var captionSize: CGFloat { 20 }
    private var codeSize: CGFloat { 64 }
    private var rowLogo: CGFloat { 40 }
    #else
    private var bodySize: CGFloat { 15 }
    private var captionSize: CGFloat { 12 }
    private var codeSize: CGFloat { 34 }
    private var rowLogo: CGFloat { 30 }
    #endif
}

struct MDBListIntegrationView: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var disconnecting = false

    var body: some View {
        NavigationStack {
            Form {
                if let account = media.mdbListAccount {
                    Section("Connected Account") {
                        LabeledContent("Account", value: "@\(account.username)")
                        if let plan = account.plan { LabeledContent("Plan", value: plan) }
                        LabeledContent("Catalogs", value: media.mdbListCatalogs.count.formatted())
                        if let remaining = account.requestsRemaining {
                            LabeledContent("API requests left", value: remaining.formatted())
                        }
                    }
                }

                Section {
                    SecureField("MDBList API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(connectTitle) {
                        Task {
                            if await media.connectMDBList(apiKey: apiKey) {
                                apiKey = ""
                                dismiss()
                            }
                        }
                    }
                    .lineupButtonStyle()
                    .disabled(media.isMDBListLoading
                        || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text(media.isMDBListConnected ? "Replace API Key" : "Connect MDBList")
                } footer: {
                    Text("Create or copy a free API key from MDBList Preferences. Lineup stores it securely in this device’s Keychain. Your MDBList lists then appear in Library → Add Shelf.")
                }

                Section {
                    Link("Open MDBList Preferences", destination: URL(string: "https://mdblist.com/preferences/")!)
                    if media.isMDBListConnected {
                        Button("Disconnect MDBList", role: .destructive) { disconnecting = true }
                            .lineupButtonStyle()
                    }
                }

                #if os(tvOS)
                Section {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .lineupButtonStyle()
                }
                #endif

                if let error = media.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("MDBList")
            #if !os(tvOS)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            #endif
            .confirmationDialog("Disconnect MDBList?", isPresented: $disconnecting,
                                titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    media.disconnectMDBList()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("MDBList shelves will be removed. Your lists on MDBList will not be changed.")
            }
        }
    }

    private var connectTitle: String {
        if media.isMDBListLoading { return "Connecting…" }
        return media.isMDBListConnected ? "Save New Key" : "Connect"
    }
}

struct InitialSourceSetupView: View {
    @State private var addingIPTV = false
    @State private var addingMedia = false

    var body: some View {
        VStack(spacing: 30) {
            PageTitle(eyebrow: "LINEUP", title: "Bring your streams together.",
                detail: "Connect live television, your own media library, or both.")
            #if os(tvOS)
            HStack(spacing: 24) {
                Button { addingIPTV = true } label: {
                    Label("Add IPTV Provider", systemImage: "dot.radiowaves.left.and.right")
                }
                Button { addingMedia = true } label: {
                    Label {
                        Text("Add Media Server")
                    } icon: {
                        MediaServerLogoRow(size: 26)
                    }
                }
            }
            .lineupButtonStyle()
            #else
            VStack(spacing: 14) {
                Button { addingIPTV = true } label: {
                    Label("Add IPTV Provider", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                Button { addingMedia = true } label: {
                    Label {
                        Text("Add Media Server")
                    } icon: {
                        MediaServerLogoRow(size: 18)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .lineupButtonStyle()
            #endif
        }
        .padding(setupPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background)
        .sheet(isPresented: $addingIPTV) {
            #if os(iOS)
            ProfileSetupView(addingProvider: true)
            #else
            ProfileSetupView()
            #endif
        }
        .sheet(isPresented: $addingMedia) { MediaServerSetupView() }
    }

    private var setupPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        24
        #endif
    }
}

#if !os(tvOS)
/// A Library shelf's header in its panel: icon and caption over a hairline,
/// with the server and See All on the right.
private struct PhoneShelfHeader<Accessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 0) {
            LineupPanelHeader(title: title, systemImage: symbol) {
                HStack(spacing: 10) { accessory() }
            }
            .padding(.top, 15).padding(.bottom, 11)
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
        }
        .padding(.horizontal, LineupPanelStyle.inset)
    }
}
#endif

#if os(tvOS)
/// A shelf's title on the television: the panels' icon and heavy caption in
/// light grey, at the size it is read at across a room.
private struct TVShelfTitle: View {
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

/// A Library shelf as a panel on the phone: its posters scroll inside the
/// card, between its edges. The television keeps its open rows.
private struct PhoneShelfPanel: ViewModifier {
    /// Under the last row: posters bring 8 of their own, other rows none.
    var bottom: CGFloat = 10

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
private struct MediaSeasonMenuAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
#endif
