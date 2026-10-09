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
    @State private var clearingHistory = false
    @State private var searchingLibrary = false
    @State private var playing: MediaPlayRequest?

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
                               searchingLibrary: $searchingLibrary)
            #else
            Group {
                if !media.hasAnySource {
                    ContentUnavailableView {
                        Label("Add a Media Server", systemImage: "play.square.stack")
                    } description: {
                        Text("Connect a Jellyfin server to watch your own library here.")
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
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    mediaOptionsMenu
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
    private var mediaOptionsMenu: some View {
        Menu {
            Button("Search", systemImage: "magnifyingglass") { searchingLibrary = true }
                .disabled(media.shelves.isEmpty)
            Button("Add Shelf", systemImage: "plus.rectangle.on.rectangle") { choosingShelf = true }
                .disabled(!media.hasAnySource)
            Menu("Remove Shelf", systemImage: "minus.rectangle") {
                ForEach(media.shelves) { shelf in
                    Button(media.shelfName(shelf), role: .destructive) { media.removeShelf(shelf) }
                }
            }
            .disabled(media.shelves.isEmpty)
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await media.reload() } }
                .disabled(media.isLoading || !media.hasAnySource)
            Button("Add Server", systemImage: "plus") { addingServer = true }
            if !media.continueWatching.isEmpty || !media.watchHistory.isEmpty {
                Button("Clear Local Tracking", systemImage: "clock.arrow.circlepath", role: .destructive) {
                    clearingHistory = true
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Library options")
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
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: cardRadius, style: .continuous),
                           fallback: LineupStyle.surface, border: LineupStyle.line)
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
    private var cardRadius: CGFloat { 20 }
    private var glyph: CGFloat { 42 }
    private var glyphSize: CGFloat { 20 }
    private var rule: CGFloat { 26 }
    #endif

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .frame(width: glyph, height: glyph)
                .lineupLiquidGlass(Circle(), fallback: LineupStyle.raised,
                                   border: LineupStyle.line)
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
            Text(status)
                .font(.inter(.caption2, .semibold))
                .foregroundStyle(statusTint)
                .lineLimit(1)
                .frame(minWidth: 74)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .lineupLiquidGlass(Capsule(), fallback: LineupStyle.raised,
                                   border: LineupStyle.line)
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
            LineupCardAction(title: "Guide", symbol: "calendar", action: openGuide)
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
        return "\(media.profiles.count) Jellyfin servers"
    }

    private var subtitle: String {
        guard media.profiles.count > 1 else {
            guard let profile = media.profiles.first else { return "" }
            return "\(profile.username) · \(URL(string: profile.serverURL)?.host ?? profile.serverURL)"
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
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.inter(.subheadline, .semibold))
                #if os(tvOS)
                .frame(maxWidth: .infinity, minHeight: 66)
                #else
                .frame(maxWidth: .infinity, minHeight: 38)
                #endif
                .lineupLiquidGlass(Capsule(), fallback: LineupStyle.raised, border: LineupStyle.line)
                .lineupFocusLayer(focused, in: Capsule())
                .scaleEffect(focused ? LineupStyle.controlLift : 1)
        }
        .lineupFlatButton()
    }
}

struct LineupStatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let connected: Bool

    #if os(tvOS)
    private static let size: CGFloat = 16
    #else
    private static let size: CGFloat = 9
    #endif

    private var tint: Color {
        connected ? Color(red: 0.29, green: 0.84, blue: 0.45) : Color.gray
    }

    var body: some View {
        // A bead rather than a filled circle: a lit upper face, a deeper base,
        // a hairline rim and one small specular. That is what reads as glass at
        // nine points, where a material effect would show nothing at all.
        // Every measurement below is a fraction of the bead rather than a
        // number, because the television draws it at nearly twice the size and
        // a specular highlight fixed at two and a half points would vanish
        // there while the rim stayed hairline-thin.
        Circle()
            .fill(RadialGradient(colors: [tint.opacity(0.98), tint.opacity(0.58)],
                                 center: UnitPoint(x: 0.34, y: 0.28),
                                 startRadius: 0, endRadius: Self.size * 0.9))
            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: Self.size * 0.056))
            .overlay(alignment: .topLeading) {
                Circle().fill(.white.opacity(0.55))
                    .frame(width: Self.size * 0.29, height: Self.size * 0.29)
                    .blur(radius: Self.size * 0.067)
                    .offset(x: Self.size * 0.167, y: Self.size * 0.144)
            }
            .frame(width: Self.size, height: Self.size)
            .shadow(color: tint.opacity(connected ? 0.5 : 0), radius: Self.size / 3)
            // Underneath, not over: the halo comes out from beneath the bead
            // and travels outward, which is the only way round that reads as
            // the dot giving something off. Drawn over the bead it washed the
            // bead out instead, and the bead is the thing worth looking at.
            //
            // It also sits in a background rather than in the layout, so its
            // travel can never move the name beside it.
            .background { halo }
            .accessibilityLabel(connected ? "Connected" : "Not connected")
    }

    /// Where the halo is in its cycle.
    ///
    /// `home` is the bead's own size, and the bead is opaque and sits on top of
    /// it, so the halo is invisible there -- it only becomes visible in the
    /// travelling, which is the point: nothing appears out of thin air around
    /// the dot, it comes out from under it.
    private enum HaloPhase: Equatable { case home, out, back }

    /// The pulse. Quiet on purpose: it leaves the bead, gets a little under
    /// twice its size, and is gone. A breath, not a beacon.
    @ViewBuilder
    private var halo: some View {
        if connected && !reduceMotion {
            Circle()
                .fill(tint)
                .frame(width: Self.size, height: Self.size)
                // A phase animator rather than a repeating animation driven by
                // state: the cycle restarts itself, so there is no stale one to
                // cancel and no way for two to overlap and send the halo
                // inward, which is what the first attempt at this did.
                .phaseAnimator([HaloPhase.home, .out, .back]) { circle, phase in
                    circle
                        .scaleEffect(phase == .out ? 1.9 : 1)
                        .opacity(phase == .home ? 0.38 : 0)
                } animation: { (phase: HaloPhase) -> Animation? in
                    switch phase {
                    // The travel, and the only part anyone sees.
                    case .out: return .easeOut(duration: 1.9)
                    // Home again while fully transparent, so the return trip
                    // -- the one that would read as a halo moving inward --
                    // happens where there is nothing to see.
                    case .back: return .linear(duration: 0.01)
                    // A beat between pulses. Also invisible: at the bead's own
                    // size the bead covers it.
                    case .home: return .easeIn(duration: 0.45)
                    }
                }
                .allowsHitTesting(false)
        }
    }
}

#if os(tvOS)
private struct TVMediaServersHome: View {
    @EnvironmentObject private var media: MediaLibrary
    @Binding var addingServer: Bool
    @Binding var choosingShelf: Bool
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
        if !media.shelves.isEmpty {
            options.append(TVLibraryOption(title: "Remove a Shelf", symbol: "minus.rectangle") {
                removingShelf = true
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
                    Image(systemName: "rectangle.stack.badge.exclamationmark").font(.system(size: 42, weight: .light))
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
        .confirmationDialog("Remove a Shelf", isPresented: $removingShelf, titleVisibility: .visible) {
            ForEach(media.shelves) { shelf in
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
    @State private var open = false
    /// Which parts of the menu hold focus. When none does, focus has gone
    /// elsewhere and the list closes behind it.
    @State private var focused: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            TVSelectable(scale: LineupStyle.controlLift, action: { open.toggle() },
                         onFocusChange: { track("menu", $0) }) {
                MediaChromeLabel {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Library")
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.inter(13, .bold))
                    }
                    .font(.inter(16, .semibold))
                }
            }
            .overlay(alignment: .topTrailing) {
                if open {
                    panel
                        .alignmentGuide(.top) { $0[.top] - 48 }
                        .transition(.opacity.combined(with: .offset(y: -8)))
                }
            }
        }
        .padding(.horizontal, 54)
        .lineupFocusRegion()
        .onExitCommand(perform: open ? { open = false } : nil)
        .animation(.easeOut(duration: 0.16), value: open)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                TVSelectable(scale: 1.02, fillRadius: 10,
                             action: { open = false; option.action() },
                             onFocusChange: { track(option.id, $0) },
                             requestInitialFocus: index == 0) {
                    HStack(spacing: 14) {
                        Image(systemName: option.symbol)
                            .frame(width: 28)
                        Text(option.title)
                        Spacer(minLength: 0)
                    }
                    .font(.inter(17, .semibold))
                    .foregroundStyle(option.destructive ? Color.red.opacity(0.92) : LineupStyle.lightPurple)
                    .padding(.horizontal, 16)
                    .frame(width: 340, height: 50)
                }
            }
        }
        .padding(8)
        .background(LineupStyle.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LineupStyle.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
        .fixedSize()
    }

    /// Notes where focus is, and closes the list a moment after it has left
    /// every part of the menu -- the moment covers focus passing from one
    /// row to the next, which reports the old row losing it first.
    private func track(_ id: String, _ isFocused: Bool) {
        if isFocused { focused.insert(id) } else { focused.remove(id) }
        guard open, focused.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if focused.isEmpty { open = false }
        }
    }
}

private struct TVMediaEmptyState: View {
    let addServer: () -> Void
    var body: some View {
        HStack(spacing: 34) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(LineupStyle.surface)
                Image(systemName: "play.square.stack.fill")
                    .font(.inter(72, .light)).foregroundStyle(LineupStyle.lightPurple)
            }
            .frame(width: 210, height: 150)
            VStack(alignment: .leading, spacing: 12) {
                Text("Bring your media to the big screen.")
                    .font(.inter(32, .semibold))
                Text("Connect your Jellyfin server and watch your own library on the big screen.")
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
    #endif

    private var continueWatching: [LocalMediaPlayback] { Array(media.continueWatching.prefix(20)) }
    private var favoriteTitles: [MediaItem] { media.favoriteMedia.filter { $0.type != "Episode" } }
    private var favoriteEpisodes: [MediaItem] { media.favoriteMedia.filter { $0.type == "Episode" } }
    #if os(tvOS)
    private var defaultPreviewItem: MediaItem? {
        continueWatching.first?.item
            ?? media.heroCatalog?.items.first
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
                                             items: group.items)
                        })
                    }
                }
            } else {
                if catalogs.isEmpty && continueWatching.isEmpty
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
                            description: Text("Add only the catalogs you want. Trending Movies and Trending TV are selected automatically when the server provides them."))
                    }
                } else {
                    #if os(tvOS)
                    ZStack(alignment: .top) {
                        TVMediaLibraryCanvas(preview: tvPreview, height: tvPreviewHeight)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: catalogSpacing) {
                                Color.clear.frame(height: tvPreviewHeight)
                                    // At the top right of the preview, clear
                                    // of its title and overview on the left,
                                    // and moving with the shelves so it never
                                    // sits over them. It takes no room of its
                                    // own, and its list opens over the
                                    // artwork beneath it.
                                    .overlay(alignment: .top) {
                                        if let options {
                                            TVLibraryMenuBar(options: options).padding(.top, 100)
                                        }
                                    }
                                    .zIndex(1)
                                libraryShelves
                            }
                            .padding(.bottom, 44)
                        }
                    }
                    // Artwork owns the television canvas. Shelf content keeps
                    // its own readable insets while the backdrop continues
                    // behind the tab bar and through every catalog row.
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                    #else
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: catalogSpacing) {
                            if let heroCatalog = media.heroCatalog {
                                MediaLibraryHero(catalog: heroCatalog, onOpen: openHeroItem)
                                    .padding(.bottom, -catalogSpacing)
                            }
                            libraryShelves
                        }
                        .padding(.bottom, 44)
                    }
                    .ignoresSafeArea(edges: .top)
                    #endif
                }
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
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

    @ViewBuilder
    private var libraryShelves: some View {
        if !continueWatching.isEmpty {
            localShelf(title: "Continue Watching", items: continueWatching.map(\.item), opensPages: true)
        }
        if !favoriteTitles.isEmpty {
            localShelf(title: "Favorites", items: favoriteTitles)
        }
        if !favoriteEpisodes.isEmpty {
            localShelf(title: "Favorite Episodes", items: favoriteEpisodes)
        }
        ForEach(catalogs) { catalog in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(catalog.title).font(sectionTitleFont)
                    // Which server a shelf comes from, once there is more than
                    // one: two of them can each have a "Trending Movies".
                    if let server = media.serverName(for: catalog) {
                        Text(server.uppercased())
                            .font(.inter(10, .bold)).tracking(1.2)
                            .foregroundStyle(LineupStyle.lightPurple.opacity(0.42))
                            .lineLimit(1)
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
                    #else
                    NavigationLink(value: catalog.root) {
                        MediaChromeLabel {
                            Label("See All", systemImage: "chevron.right")
                                .font(.inter(14, .semibold))
                        }
                    }.lineupFlatButton()
                    #endif
                }
                .padding(.horizontal, horizontalPadding)
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
                            ForEach(catalog.items, id: \.libraryKey) { item in
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
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                    .lineupFocusRegion()
                }
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
            let candidates = media.heroCatalog.map { MediaHeroCatalogSelection.featuredItems(in: $0) } ?? []
            guard !candidates.isEmpty else {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                continue
            }
            let current = tvPreview.item.flatMap { current in
                candidates.firstIndex(where: { $0.id == current.id })
            } ?? -1
            let next = candidates[(current + 1) % candidates.count]
            // Spend the eight-second dwell preloading the next frame. On a
            // normal connection the transition therefore begins with decoded
            // artwork already in memory, without making the interval longer.
            Task { await preloadBackdrop(for: next) }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard !tvPreview.isNavigating, !Task.isCancelled else { continue }
            // A weak connection may miss this particular turn, but the hero
            // never rotates to a blank frame. The already-running shared load
            // keeps going and the next eight-second tick can use it.
            guard backdropIsReady(for: next) else { continue }
            withAnimation(.easeInOut(duration: 0.45)) {
                tvPreview.rotate(to: next) { item in
                    try? await media.details(of: item)
                }
            }
        }
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

    private var tvPreviewHeight: CGFloat { 500 }
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
    private func localShelf(title: String, items: [MediaItem], opensPages: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(sectionTitleFont)
                Text("ON THIS DEVICE")
                    .font(.inter(10, .bold)).tracking(1.2)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.42))
                Spacer()
            }
            .padding(.horizontal, horizontalPadding)
            .lineupFocusRegion()
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
        16
        #endif
    }
    private var catalogSpacing: CGFloat {
        #if os(tvOS)
        32
        #else
        26
        #endif
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
        .inter(24, .semibold)
        #else
        .inter(.title3, .bold)
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
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        70
        #else
        16
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
        if item.hasDetailPage || item.isPlayable {
            MediaDetailScreen(item: item)
        } else {
            MediaFolderScreen(folder: item)
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
            return [Group(id: server.id.uuidString + "|libraries", title: "LIBRARIES" + owner,
                          detail: several ? "Folders \(server.name) keeps itself" : "Folders this server keeps itself",
                          items: media.availableLibraries(on: server)),
                    Group(id: server.id.uuidString + "|catalogs", title: "IMPORTED CATALOGS" + owner,
                          detail: several ? "Already on \(server.name), ready to shelve" : "Already on your server, ready to shelve",
                          items: media.availableCatalogs(on: server))]
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
        !groups.isEmpty || !media.addonGroups.isEmpty || !media.availableMDBListCatalogs.isEmpty
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ADD A SHELF").font(.inter(12, .heavy)).tracking(1.6)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
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
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.title).font(.inter(12, .heavy)).tracking(1.6)
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
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
                            Text(group.section.title).font(.inter(12, .heavy)).tracking(1.6)
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
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
                            Text(addonHeading(group))
                                .font(.inter(12, .heavy)).tracking(1.6)
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
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
        .background(LineupStyle.surface.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    #endif
    @State private var choosingSeason = false
    #if !os(tvOS)
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
        .modifier(FullBleedHeader())
        .task(id: item.libraryKey) { await load() }
        #if !os(tvOS)
        .task(id: item.libraryKey) { pageRatings = await media.ratings(for: item) }
        #endif
        #if os(tvOS)
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
        .toolbar(.hidden, for: .tabBar)
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
                        .font(.system(size: 24, weight: .bold))
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
        return nextUp ?? episodes.first { !$0.isPlayed } ?? episodes.first
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
        let label = Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
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
            seasonHeading.padding(.horizontal, horizontalPadding).lineupFocusRegion()
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
                Text("Trailers").font(sectionTitleFont)
                    .padding(.horizontal, horizontalPadding)
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
                    .font(.system(size: 24, weight: .bold))
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
                Text("Cast").font(sectionTitleFont)
                    .padding(.horizontal, horizontalPadding)
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
                                                .font(.largeTitle)
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
        }
    }

    @ViewBuilder
    private var relatedSection: some View {
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                // Named for what it holds, because a row of posters under a
                // bare "Related" does not say whether it is offering films or
                // series.
                Text(subject.isSeries ? "Related Shows" : "Related Movies")
                    .font(sectionTitleFont)
                    .padding(.horizontal, horizontalPadding)
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
        }
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
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
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
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
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
            let up = await media.nextUp(in: item)
            if let up { media.rememberNextUp(up) }
            // Where Continue Watching has the viewer -- an episode part-watched
            // on this device first, then the server's next one -- and the
            // season it is in, so a show opened from there opens where they
            // were, with every other episode a choice away.
            nextUp = media.continueWatchingEpisode(in: subject) ?? up
            await loadSeason(seasonList.first { $0.indexNumber == nextUp?.parentIndexNumber } ?? seasonList[0])
            pageReady = true
        } catch {
            self.error = error.localizedDescription
            loading = false
            pageReady = true
        }
    }

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
        16
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
        .inter(40, .bold)
        #else
        .inter(.title, .bold)
        #endif
    }
    private var sectionTitleFont: Font {
        #if os(tvOS)
        .inter(24, .semibold)
        #else
        .inter(.title3, .bold)
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
                            else { Image(systemName: "film.fill").font(.largeTitle) }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let playback {
                            MediaArtworkProgress(fraction: playback.fraction,
                                                 label: artworkLabel(playback.label))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .lineupFocusLayer(episodeArtworkIsFocused, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if playback?.watched == true {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
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

    private var playbackPresentation: (fraction: Double, label: String, watched: Bool)? {
        media.cardPlaybackPresentation(for: episode)
    }

    /// The episode's code is printed under the still already, so on the still
    /// itself only the time is said.
    private func artworkLabel(_ label: String) -> String {
        guard let code = episode.episodeCode, label.hasPrefix(code + " · ") else { return label }
        return String(label.dropFirst(code.count + 3))
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
        guard focused, item?.libraryKey != key else { return }
        detailLoad?.cancel()
        item = details[key] ?? focusedItem
        guard details[key] == nil else { return }
        detailLoad = Task { [weak self] in
            // A swipe can cross several posters. The shelf item changes the
            // art immediately; rich metadata waits for focus to settle.
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard !Task.isCancelled, let loaded = await load(focusedItem),
                  !Task.isCancelled, self?.item?.libraryKey == key else { return }
            self?.details[key] = loaded
            self?.item = loaded
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
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            TVMediaCinematicBackdrop(item: preview.item)
            TVMediaLibraryPreview(item: preview.item)
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }
}

/// The artwork plane behind both Library browsing and the selected-title page.
/// It is fixed while shelves move, so focus changes the room rather than
/// repainting a rectangle behind one row.
private struct TVMediaCinematicBackdrop: View {
    @EnvironmentObject private var media: MediaLibrary
    let item: MediaItem?

    var body: some View {
        ZStack {
            LineupStyle.background
            if let item {
                LineupArtView(url: media.backdropURL(for: item, width: 1920)
                              ?? media.imageURL(for: item, width: 1920), width: 1920) { loaded in
                    if let loaded { loaded.resizable().scaledToFill() }
                    else { Color.clear }
                }
                .id(item.id)
                .transition(.opacity)
            }
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
        .animation(.easeInOut(duration: 0.32), value: item?.id)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Focused-title context that stays above the shelves. Sparse catalog entries
/// show what they have immediately; the detail fetch enriches the same view
/// with logo, cast and metadata without changing its geometry.
private struct TVMediaLibraryPreview: View {
    @EnvironmentObject private var media: MediaLibrary
    let item: MediaItem?
    /// Each title's ratings once found. The hero moves on every few seconds
    /// and comes back round, and a title it has shown keeps its chips.
    @State private var ratings: [String: MediaRatings] = [:]

    var body: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 13) {
                    titleLockup(item)
                    if let shown = ratings[item.libraryKey] ?? media.knownRatings(for: item), !shown.isEmpty {
                        MediaRatingChips(ratings: shown)
                    }
                    if !metadata(item).isEmpty {
                        Text(metadata(item).joined(separator: "  ·  "))
                            .font(.inter(19, .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.75), radius: 10, y: 2)
                    }
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.inter(18, .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(3)
                            .frame(maxWidth: 820, alignment: .leading)
                            .shadow(color: .black.opacity(0.75), radius: 10, y: 2)
                    }
                    castLine(item)
                }
                .id(item.id)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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

    private var catalogs: [MediaCatalog] { media.catalogs.filter { !$0.items.isEmpty } }

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageTitle(eyebrow: "Library", title: "Library Hero",
                          detail: "Choose the catalog whose first ten titles fill the Library hero.")
                if catalogs.isEmpty {
                    ContentUnavailableView("No Catalogs", systemImage: "rectangle.stack.badge.plus",
                        description: Text("Add a shelf in Library, then choose it here."))
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .mediaFocusAnchor()
                } else {
                    VStack(spacing: 14) {
                        ForEach(catalogs) { catalog in
                            TVSelectable(scale: LineupStyle.controlLift,
                                         action: { media.selectHeroCatalog(catalog) }) {
                                catalogRow(catalog)
                            }
                        }
                    }
                    .lineupFocusRegion()
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 70).padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(LineupStyle.background.ignoresSafeArea())
        #else
        List {
            if catalogs.isEmpty {
                ContentUnavailableView("No Catalogs", systemImage: "rectangle.stack.badge.plus",
                    description: Text("Add a shelf in Library, then choose it here."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(catalogs) { catalog in
                        Button { media.selectHeroCatalog(catalog) } label: { catalogRow(catalog) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    Text("The first ten titles in this catalog become the swipeable Library hero.")
                }
                .listRowBackground(LineupGlassRow())
            }
        }
        .scrollContentBackground(.hidden)
        .background(LineupStyle.background)
        .navigationTitle("Library Hero")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func catalogRow(_ catalog: MediaCatalog) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: rowSymbolSize, weight: .semibold))
                .foregroundStyle(LineupStyle.highlight)
                .frame(width: rowSymbolFrame)
            VStack(alignment: .leading, spacing: 4) {
                Text(catalog.title).font(.inter(rowTitleSize, .semibold)).lineLimit(1)
                Text("\(min(10, catalog.items.count)) featured title\(min(10, catalog.items.count) == 1 ? "" : "s")"
                     + (media.serverName(for: catalog).map { " · " + $0 } ?? ""))
                    .font(.inter(rowDetailSize))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.58))
            }
            Spacer(minLength: 12)
            if media.heroCatalog?.id == catalog.id {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: checkSize, weight: .semibold))
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
    #else
    private var rowSymbolSize: CGFloat { 20 }
    private var rowSymbolFrame: CGFloat { 30 }
    private var rowTitleSize: CGFloat { 16 }
    private var rowDetailSize: CGFloat { 13 }
    private var checkSize: CGFloat { 20 }
    private var rowHorizontalPadding: CGFloat { 0 }
    private var rowHeight: CGFloat { 58 }
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

private struct MediaSourcePicker: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    /// Play from the beginning rather than from the saved place.
    var startsOver = false
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
            .fullScreenCover(item: $selectedSource, onDismiss: { if playedOnlySource { dismiss() } }) { source in
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
            return StreamServerStatus(id: lookup.id, name: lookup.name, phase: phase)
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
                    if index == ownIndex { failure = problem }
                    if let miss = problem as? MediaLibrary.StreamLookupError {
                        serverStatus[index].phase = .notOnServer(tried: miss.tried)
                    } else if !MediaLibrary.isCancellation(problem) {
                        serverStatus[index].phase = .failed(problem.localizedDescription)
                    }
                }
                sources = found.keys.sorted().flatMap { found[$0] ?? [] }
                if !sources.isEmpty { loading = false }
            }
        }
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
                       synopsis: tvPlayerSynopsis)
            #else
            MobilePlayerView(name: item.name, urls: [url], isLive: false,
                             sourceBitrate: source.formattedBitrate,
                             sourceQuality: source.quality,
                             synopsis: playerSynopsis,
                             initialPosition: media.resumePosition(for: item)) { position, duration in
                media.trackPlayback(of: item, position: position, duration: duration)
            }
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
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
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
                    tab(status.name, title: status.name, mark: status.mark)
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

    private func tab(_ value: String?, title: String, mark: MediaStreamTab.Mark) -> some View {
        Button { filter = value } label: {
            MediaStreamTab(title: title, mark: mark, active: filter == value)
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
            Text(section.title.uppercased())
                .font(.inter(Style.sectionSize, .heavy)).tracking(Style.eyebrowTracking)
            Spacer()
            Text("\(section.sources.count)")
                .font(.interDigits(Style.sectionSize, .heavy))
        }
        .foregroundStyle(LineupStyle.lightPurple.opacity(0.5))
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
                        Text(status.failure == nil ? "\(status.name) doesn't have this title"
                                                   : "\(status.name) didn't answer")
                            .font(.inter(Style.noteSize, .semibold))
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
                .font(.system(size: Style.noticeSymbolSize, weight: .semibold))
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

    private typealias Style = MediaStreamStyle

    var body: some View {
        HStack(spacing: Style.tabInnerGap) {
            Text(title).font(.inter(Style.tabSize, .semibold)).lineLimit(1)
            markView
        }
        .padding(.horizontal, Style.tabPadH).padding(.vertical, Style.tabPadV)
        .foregroundStyle(active ? LineupStyle.background : LineupStyle.lightPurple)
        .background(active ? LineupStyle.lightPurple : LineupStyle.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? Color.clear : LineupStyle.line, lineWidth: 1))
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
                .tint(active ? LineupStyle.background : LineupStyle.lightPurple)
                .scaleEffect(Style.tabSpinnerScale)
                .frame(width: Style.tabSpinner, height: Style.tabSpinner)
        case .missing:
            Text("—").font(.inter(Style.tabCountSize, .bold)).opacity(0.5)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Style.tabCountSize - 3, weight: .bold)).opacity(0.6)
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
        .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: Style.rowRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Style.rowRadius, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
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
    static let eyebrowSize: CGFloat = 11
    static let eyebrowTracking: CGFloat = 1.6
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
    static let sectionSize: CGFloat = 11
    static let sectionGap: CGFloat = 22
    static let rowSpacing: CGFloat = 8
    static let rowRadius: CGFloat = 14
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
                chip("IMDb", spoken: "IMDb", value: String(format: "%.1f", imdb), tint: Metrics.imdb)
            }
            if let tmdb = ratings.tmdb {
                chip("TMDB", spoken: "TMDB", value: String(format: "%.1f", tmdb), tint: Metrics.tmdb)
            }
            if let tomatoes = ratings.rottenTomatoes {
                chip("RT", spoken: "Rotten Tomatoes", value: "\(tomatoes)%", tint: Metrics.rottenTomatoes)
            }
        }
        .fixedSize()
    }

    private func chip(_ source: String, spoken: String, value: String, tint: Color) -> some View {
        HStack(spacing: Metrics.inner) {
            Text(source)
                .font(.inter(Metrics.sourceSize, .heavy))
                .foregroundStyle(tint)
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
    // The sites' own colours: IMDb's yellow, TMDB's blue, the Tomatometer's red.
    static let imdb = Color(red: 0.96, green: 0.77, blue: 0.09)
    static let tmdb = Color(red: 0.0, green: 0.71, blue: 0.89)
    static let rottenTomatoes = Color(red: 0.98, green: 0.24, blue: 0.1)
    static let fill = Color(red: 0.15, green: 0.16, blue: 0.19).opacity(0.9)
    #if os(tvOS)
    static let height: CGFloat = 42
    static let padding: CGFloat = 15
    static let gap: CGFloat = 12
    static let inner: CGFloat = 10
    static let sourceSize: CGFloat = 19
    static let valueSize: CGFloat = 22
    static let radius: CGFloat = 10
    #else
    static let height: CGFloat = 30
    static let padding: CGFloat = 10
    static let gap: CGFloat = 8
    static let inner: CGFloat = 7
    static let sourceSize: CGFloat = 13
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
                        LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                        LineupArtView(url: artworkURL, width: artWidth) { loaded in
                            if let image = loaded { image.resizable().scaledToFill() }
                            else { Image(systemName: item.isFolder ? "rectangle.stack.fill" : "film.fill").font(.largeTitle) }
                        }
                    }
                    // Where the viewer is, on the art rather than under it: a
                    // row's titles then sit on one line whether or not a card
                    // has been started.
                    .overlay(alignment: .bottom) {
                        if let playback {
                            MediaArtworkProgress(fraction: playback.fraction, label: playback.label)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .lineupFocusLayer(artworkIsFocused, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if playback?.watched == true {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
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
                Text(item.type.uppercased())
                if let year = item.productionYear { Text("· \(String(year))") }
                if let count = item.childCount { Text("· \(count)") }
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


    private var playbackPresentation: (fraction: Double, label: String, watched: Bool)? {
        media.cardPlaybackPresentation(for: item)
    }

    /// The widest this card is ever drawn -- the top of the grid's adaptive
    /// range, which is wider than the fixed width a shelf gives it. One size
    /// per shape means a title scrolled past in a shelf and met again in a
    /// grid is the same cached picture both times.
    private var artWidth: CGFloat {
        #if os(tvOS)
        shape == .poster ? 310 : 460
        #else
        shape == .poster ? 210 : 300
        #endif
    }
    private var artworkURL: URL? {
        if shape.isPoster, item.type == "Episode" {
            return media.seriesPosterURL(for: item, width: Int(artWidth))
                ?? media.imageURL(for: item, width: Int(artWidth))
        }
        return media.imageURL(for: item, width: Int(artWidth))
    }
    private var cardRadius: CGFloat {
        #if os(tvOS)
        18
        #else
        12
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
private struct MediaArtworkProgress: View {
    let fraction: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(label)
                .font(.inter(labelSize, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: trackHeight)
        }
        .padding(.horizontal, inset)
        .padding(.bottom, inset)
        .padding(.top, inset * 2.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.55), location: 0.45),
                .init(color: .black.opacity(0.82), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    #if os(tvOS)
    private var labelSize: CGFloat { 16 }
    private var trackHeight: CGFloat { 5 }
    private var spacing: CGFloat { 8 }
    private var inset: CGFloat { 12 }
    #else
    private var labelSize: CGFloat { 11 }
    private var trackHeight: CGFloat { 3 }
    private var spacing: CGFloat { 5 }
    private var inset: CGFloat { 8 }
    #endif
}

struct MediaServerSetupView: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Jellyfin-Compatible Server") {
                    TextField("Display name", text: $name)
                    TextField("Server address", text: $server)
                        #if !os(tvOS)
                        .keyboardType(.URL).textContentType(.URL)
                        #endif
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
                // The provider form has always had these and this one never
                // did. A capitalised host or an autocorrected one is not the
                // address anybody meant to type, and on a television, where
                // every character costs a click, it is not obvious what went
                // wrong either.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section {
                    Button(media.isAddingServer ? "Connecting…" : "Connect") {
                        Task {
                            if await media.addServer(name: name, serverURL: server,
                                username: username, password: password) { dismiss() }
                        }
                    }
                        .lineupButtonStyle()
                    // A password is not required. Jellyfin-compatible servers
                    // allow passwordless users, and some ship that way until an
                    // operator sets one -- refusing to try left those servers
                    // unreachable with the button simply dead.
                    .disabled(media.isAddingServer
                        || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Connect a Jellyfin server. The address can be just the host and port, like 192.168.1.50:8096. Leave the password blank for a user that has none. Every server you add feeds the Library together. Access tokens are stored securely in this device’s Keychain.")
                }
                #if os(tvOS)
                // A television draws no navigation bar, so the toolbar's
                // Cancel is never rendered and the form has no visible way
                // out. It gets a row of its own here.
                Section {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .lineupButtonStyle()
                }
                #endif
                if let error = media.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Media Server")
            #if !os(tvOS)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            #endif
            .disabled(media.isAddingServer)
        }
    }
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
                    Label("Add Media Server", systemImage: "play.square.stack")
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
                    Label("Add Media Server", systemImage: "play.square.stack")
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
