import SwiftUI
#if os(tvOS)
import UIKit
#endif

struct MediaServersView: View {
    @EnvironmentObject private var media: MediaLibrary
    @State private var addingServer = false
    @State private var choosingShelf = false

    var body: some View {
        NavigationStack {
            Group {
            #if os(tvOS)
            TVMediaServersHome(addingServer: $addingServer, choosingShelf: $choosingShelf)
            #else
            Group {
                if !media.hasAnySource {
                    ContentUnavailableView {
                        Label("Add a Media Server", systemImage: "play.square.stack")
                    } description: {
                        Text("Connect a Jellyfin, Nullfin, or other Jellyfin-compatible server to watch your own library here.")
                    } actions: {
                        Button("Add Media Server", systemImage: "plus") { addingServer = true }
                    }
                } else if media.shelves.isEmpty && media.isLoading {
                    ProgressView("Loading libraries…")
                } else if media.shelves.isEmpty && media.loadFailed {
                    // Not "Choose Your Shelves". An attempt that failed and a
                    // server with nothing selected look identical from here,
                    // and telling a viewer to pick shelves that could not be
                    // fetched sends them looking for a setting to fix.
                    ContentUnavailableView {
                        Label("Can't Reach Your Server", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Lineup couldn't load your libraries. Check that the server is running and reachable from this network.")
                    } actions: {
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            Task { await media.reload() }
                        }
                    }
                } else {
                    MediaCatalogsScreen(catalogs: media.shelves)
                }
            }
            .background(LineupStyle.background.ignoresSafeArea())
            .navigationTitle("Media Servers")
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
            .onAppear { media.loadShelvesIfNeeded() }
            .onChange(of: media.activeProfile?.id) { _, _ in media.loadShelvesIfNeeded() }
            .alert("Media Server", isPresented: Binding(
                get: { media.errorMessage != nil },
                set: { if !$0 { media.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(media.errorMessage ?? "Unknown error") }
        }
    }

    #if !os(tvOS)
    private var mediaOptionsMenu: some View {
        Menu {
            Button("Add Shelf", systemImage: "plus.rectangle.on.rectangle") { choosingShelf = true }
                .disabled(!media.hasAnySource)
            Menu("Remove Shelf", systemImage: "minus.rectangle") {
                ForEach(media.shelves) { shelf in
                    Button(shelf.title, role: .destructive) { media.removeShelf(shelf) }
                }
            }
            .disabled(media.shelves.isEmpty)
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await media.reload() } }
                .disabled(media.isLoading || !media.hasAnySource)
            Button("Add Server", systemImage: "plus") { addingServer = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Media options")
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

/// A compact account summary of the selected server. Counts come from the
/// server's total-record queries, never from the first page of shelf cards.
struct MediaServerAccountCard: View {
    @EnvironmentObject private var media: MediaLibrary
    let profile: MediaServerProfile
    let browse: () -> Void

    var body: some View {
        LineupAccountCard(
            symbol: "play.square.stack.fill",
            title: profile.name,
            subtitle: "\(profile.username) · \(URL(string: profile.serverURL)?.host ?? profile.serverURL)",
            connected: media.isConnected,
            status: media.isLoading ? "Connecting…" : (media.isConnected ? "Connected" : "Offline"),
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
                .lineupLiquidGlass(Capsule(),
                                   fallback: focused ? LineupStyle.focused : LineupStyle.raised,
                                   border: LineupStyle.line)
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
    @State private var optionsVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MEDIA SERVERS")
                        .font(.inter(13, .bold)).tracking(2.2)
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    Text(media.activeProfile?.name ?? "Your library")
                        .font(.inter(34, .semibold))
                        .foregroundStyle(LineupStyle.lightPurple)
                }
                Spacer()
                if let profile = media.activeProfile {
                    Label(profile.username, systemImage: "checkmark.circle.fill")
                        .font(.inter(15, .semibold))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.72))
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(LineupStyle.surface, in: Capsule())
                }
                TVSelectable(scale: LineupStyle.controlLift, action: { optionsVisible = true }) {
                    Image(systemName: "ellipsis.circle").frame(width: 42, height: 42)
                        .modifier(MediaChromeSurface(radius: 11))
                }
            }
            .padding(.horizontal, 54).padding(.top, 18)
            .lineupFocusRegion()
            .confirmationDialog("Media Options", isPresented: $optionsVisible, titleVisibility: .visible) {
                Button("Add Shelf", systemImage: "plus.rectangle.on.rectangle") { choosingShelf = true }
                    .disabled(!media.hasAnySource)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await media.reload() } }
                    .disabled(media.isLoading || !media.hasAnySource)
                Button("Add Server", systemImage: "plus") { addingServer = true }
                ForEach(media.shelves) { shelf in
                    Button("Remove \(shelf.title)", role: .destructive) { media.removeShelf(shelf) }
                }
                Button("Cancel", role: .cancel) { }
            }

            if !media.hasAnySource {
                TVMediaEmptyState(addServer: { addingServer = true })
            } else if media.shelves.isEmpty && media.isLoading {
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
                    Text("Refresh the server, or confirm this account can access a library.")
                        .font(.inter(.callout)).opacity(0.68)
                }
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaCatalogsScreen(catalogs: media.shelves)
            }
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
                Image(systemName: "play.square.stack.fill")
                    .font(.inter(72, .light)).foregroundStyle(LineupStyle.lightPurple)
            }
            .frame(width: 210, height: 150)
            VStack(alignment: .leading, spacing: 12) {
                Text("Bring your media to the big screen.")
                    .font(.inter(32, .semibold))
                Text("Connect a Jellyfin, Nullfin, or other Jellyfin-compatible server and watch your own library on the big screen.")
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
                .background(focused ? LineupStyle.focused : LineupStyle.surface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .scaleEffect(focused ? LineupStyle.controlLift : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: focused)
        }
    }
}
#endif

private struct MediaCatalogsScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let catalogs: [MediaCatalog]
    @State private var query = ""
    // On tvOS the sheet edits a draft. Search only the submitted value: remote
    // typing otherwise launches and cancels a network search for every letter.
    @State private var submittedQuery = ""
    @State private var searchRequestID = UUID()
    @State private var results: [MediaItem] = []
    @State private var searching = false
    @State private var searchError: String?
    @FocusState private var searchFocused: Bool
    // tvOS pushes by hand because its cards are not NavigationLinks any more.
    @State private var pushed: MediaItem?
    @State private var editingQuery = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                #if os(tvOS)
                TVSelectable(scale: LineupStyle.cardLift, action: { editingQuery = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").opacity(0.58)
                        Text(query.isEmpty ? "Search movies and shows" : query)
                            .lineLimit(1).truncationMode(.tail)
                            .opacity(query.isEmpty ? 0.58 : 1)
                        if searching { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                    }
                    .font(searchFont).padding(.horizontal, 16).frame(height: searchHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(MediaChromeSurface(outline: true, radius: 13))
                }
                .sheet(isPresented: $editingQuery) { searchSheet }
                #else
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").opacity(0.58)
                    TextField("Search movies and shows", text: $query).textFieldStyle(.plain)
                    if searching { ProgressView().controlSize(.small) }
                    if !query.isEmpty {
                        Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .lineupFlatButton()
                    }
                }
                .font(searchFont).padding(.horizontal, 16).frame(height: searchHeight)
                .modifier(MediaChromeSurface(focused: searchFocused, outline: true, radius: 13))
                .focused($searchFocused)
                .focusEffectDisabled()
                #endif
            }
            .padding(.horizontal, horizontalPadding).padding(.bottom, 18)
            .lineupFocusRegion()

            if !submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if searching && results.isEmpty {
                    ProgressView("Searching your library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let searchError {
                    ContentUnavailableView("Search Unavailable", systemImage: "exclamationmark.triangle", description: Text(searchError))
                } else if results.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                        description: Text("Nothing in your connected libraries matched that."))
                } else {
                    MediaGridScreen(title: "Search Results", items: results)
                }
            } else {
                if catalogs.isEmpty {
                    ContentUnavailableView("Choose Your Shelves", systemImage: "rectangle.stack.badge.plus",
                        description: Text("Add only the catalogs you want. Trending Movies and Trending TV are selected automatically when the server provides them."))
                } else { ScrollView {
                    LazyVStack(alignment: .leading, spacing: catalogSpacing) {
                        ForEach(catalogs) { catalog in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(catalog.title).font(sectionTitleFont)
                                    Spacer()
                                    #if os(tvOS)
                                    TVSelectable(scale: LineupStyle.controlLift, action: { pushed = catalog.root }) {
                                        MediaChromeLabel {
                                            Label("See All", systemImage: "chevron.right")
                                                .font(.inter(14, .semibold))
                                        }
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
                                .lineupFocusRegion()
                                if catalog.items.isEmpty {
                                    Text("No titles in this catalog.").font(.inter(.callout))
                                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.58)).frame(height: 64)
                                        .padding(.horizontal, horizontalPadding)
                                } else {
                                    // The shelf spans the full width and insets its
                                    // content instead, so a card scrolls away at the
                                    // screen edge rather than being clipped by the
                                    // margin with the first one cut in half at rest.
                                    let shape = MediaArtShape.forItems(catalog.items)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        LazyHStack(alignment: .top, spacing: itemSpacing) {
                                            ForEach(catalog.items) { item in
                                                Group {
                                                    if item.opensPage {
                                                        #if os(tvOS)
                                                        TVSelectable(action: { pushed = item }) { MediaItemCard(item: item, shape: shape) }
                                                        #else
                                                        NavigationLink(value: item) { MediaItemCard(item: item, shape: shape) }
                                                            .lineupFlatButton()
                                                        #endif
                                                    } else { MediaPlayableCard(item: item, shape: shape) }
                                                }.frame(width: cardWidth(shape))
                                            }
                                        }
                                        .padding(.vertical, 8)
                                    }
                                    .contentMargins(.horizontal, horizontalPadding, for: .scrollContent)
                                    // Each shelf is its own region: a card
                                    // scrolled far along a row has nothing
                                    // above it but the margin of the row above.
                                    .lineupFocusRegion()
                                }
                            }
                        }
                    }
                    .padding(.bottom, 44)
                } }
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        #if !os(tvOS)
        .onChange(of: query) { _, value in
            submittedQuery = value
            searchRequestID = UUID()
        }
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
    }

    #if os(tvOS)
    /// The field lives here rather than on the shelf screen. tvOS draws its own
    /// heavy treatment around a focused text field, and that is the one frame
    /// this app cannot restyle, so it is kept off the screen behind it.
    private var searchSheet: some View {
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
                    query = ""; submittedQuery = ""; results = []
                    searchRequestID = UUID()
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
    }

    private func submitSearch() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searching = !value.isEmpty
        submittedQuery = value
        searchRequestID = UUID()
        editingQuery = false
    }
    #endif

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
    private var searchFont: Font {
        #if os(tvOS)
        .inter(19, .medium)
        #else
        .inter(.body)
        #endif
    }
    private var searchHeight: CGFloat {
        #if os(tvOS)
        54
        #else
        46
        #endif
    }
}

private struct MediaGridScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let title: String
    let items: [MediaItem]
    // tvOS pushes by hand because its cards are not NavigationLinks any more.
    @State private var pushed: MediaItem?
    @State private var choosingShelf = false
    @State private var editingQuery = false

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(items) { item in
                    if item.opensPage {
                        #if os(tvOS)
                        TVSelectable(action: { pushed = item }) { MediaItemCard(item: item, shape: shape) }
                        #else
                        NavigationLink(value: item) { MediaItemCard(item: item, shape: shape) }
                            .lineupFlatButton()
                        #endif
                    } else {
                        MediaPlayableCard(item: item, shape: shape)
                    }
                }
            }
            .padding(.horizontal, horizontalPadding).padding(.vertical, 28)
        }
        .lineupFocusRegion()
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
private struct MediaBrowseDestination: View {
    let item: MediaItem

    var body: some View {
        if item.hasDetailPage {
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
        .task(id: folder.id) {
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
        let detail: String
        let items: [MediaItem]
    }

    private var groups: [Group] {
        [Group(id: "LIBRARIES", detail: "Folders this server keeps itself",
               items: media.availableLibraries),
         Group(id: "IMPORTED CATALOGS", detail: "Already on your server, ready to shelve",
               items: media.availableCatalogs)]
            .filter { !$0.items.isEmpty }
    }

    private var hasAnything: Bool {
        !groups.isEmpty || !media.addonGroups.isEmpty
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ADD A SHELF").font(.inter(12, .heavy)).tracking(1.6)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
                Text("Pick a row for the Media Servers tab")
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
        .task { await media.loadAddonCatalogs() }
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
        .task { await media.loadAddonCatalogs() }
        #endif
    }

    @ViewBuilder
    private var list: some View {
        if !hasAnything {
            ContentUnavailableView("Every Shelf Is Showing", systemImage: "rectangle.stack.badge.plus",
                description: Text(media.addonsUnavailable
                    ? "This server offers no other library or catalog, and it does not let this account browse its catalogs -- sign in as an administrator to switch them on from here."
                    : "This server offers no other library or catalog."))
                .mediaFocusAnchor()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.id).font(.inter(12, .heavy)).tracking(1.6)
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
                            Text(group.detail).font(.inter(13))
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.4))
                        }
                        .padding(.top, 18).padding(.bottom, 6)
                        ForEach(group.items) { item in
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift, fill: LineupStyle.focused,
                                fillRadius: 14, action: { add(item) }) {
                                MediaShelfRow(title: item.name, detail: countText(item),
                                    busy: adding.contains(item.id))
                            }
                            #else
                            Button { add(item) } label: {
                                MediaShelfRow(title: item.name, detail: countText(item),
                                    busy: adding.contains(item.id))
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
                            Text(group.name.uppercased())
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
                            let busy = media.importing.contains(catalog.catalogId)
                            #if os(tvOS)
                            TVSelectable(scale: LineupStyle.cardLift, fill: LineupStyle.focused, fillRadius: 14,
                                action: { enable(catalog, in: group.id) }) {
                                MediaShelfRow(title: catalog.name,
                                    detail: busy ? "Importing… select again to stop waiting" : nil,
                                    busy: busy)
                            }
                            #else
                            Button { enable(catalog, in: group.id) } label: {
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
        guard !adding.contains(item.id) else { return }
        adding.insert(item.id)
        Task { @MainActor in
            await media.addShelf(item)
            adding.remove(item.id)
        }
    }

    /// Switching a catalog on is the server's work, not this screen's: it can
    /// run for minutes, so it is left with the library and the row simply
    /// reports it. Closing this screen does not cancel it.
    ///
    /// Pressing a row that is already working calls the waiting off, so nobody
    /// is held by a spinner they cannot get out of. The server carries on.
    private func enable(_ catalog: NullfinCatalog, in addonID: String) {
        if media.importing.contains(catalog.catalogId) {
            media.stopWaiting(for: catalog)
        } else {
            media.enableCatalog(catalog, addonID: addonID)
        }
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
    @FocusState private var seasonFocused: Bool
    #if os(tvOS)
    @FocusState private var backFocused: Bool
    #endif
    @State private var choosingSeason = false

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
        .task(id: item.id) { await load() }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $chosen) { episode in MediaSourcePicker(item: episode) }
        #else
        .sheet(item: $chosen) { episode in MediaSourcePicker(item: episode) }
        #endif
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                VStack(alignment: .leading, spacing: 16) {
                    Text(subject.name).font(titleFont)
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
    }

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
        [subject.communityRating.flatMap { $0 > 0 ? String(format: "IMDb %.1f", $0) : nil },
         subject.productionYear.map(String.init),
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
            Button { chosen = playTarget } label: { playLabel }
            .lineupFlatButton()
            .disabled(playTarget == nil)
            .opacity(playTarget == nil ? 0.45 : 1)

            // The server keeps the viewer's account of what is marked, so
            // these write through to it rather than to anything local.
            Group {
                iconButton(favorite ? "heart.fill" : "heart") {
                    favorite.toggle()
                    Task { await media.setFavorite(favorite, for: subject) }
                }
                iconButton(watched ? "eye.fill" : "eye") {
                    watched.toggle()
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
    /// On a television it is as wide as what it says and no paler than anything
    /// else on the page: a full-width filled bar was the loudest thing on the
    /// screen for a control that starts one episode, and at that size the white
    /// read as a slab rather than a button. A phone keeps the filled bar --
    /// there it is the one thing a thumb goes for, and a full-width primary
    /// action is how every other app on the platform says so.
    @ViewBuilder
    private var playLabel: some View {
        let text = HStack(spacing: 8) {
            Image(systemName: "play.fill")
            Text("Play").font(.inter(17, .semibold))
            if let code = playTarget?.episodeCode {
                Text(code).foregroundStyle(playCodeTint)
            }
        }
        .font(.inter(17))
        #if os(tvOS)
        text.padding(.horizontal, 22).frame(height: buttonHeight)
            .modifier(MediaChromeFocus())
        #else
        text.frame(maxWidth: .infinity).frame(height: buttonHeight)
            .modifier(MediaChromeFocus(prominent: true))
        #endif
    }

    /// The episode code beside "Play", quieter than the word itself -- which
    /// means a dark tint on the phone's filled bar and a pale one on the
    /// television's outlined button.
    private var playCodeTint: Color {
        #if os(tvOS)
        LineupStyle.lightPurple.opacity(0.55)
        #else
        LineupStyle.background.opacity(0.5)
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
                LazyVGrid(columns: episodeColumns, spacing: 22) {
                    ForEach(episodes) { episode in
                        Button { chosen = episode } label: { MediaEpisodeCard(episode: episode) }
                            .lineupFlatButton()
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .lineupFocusRegion()
                #else
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(episodes) { episode in
                            Button { chosen = episode } label: { MediaEpisodeCard(episode: episode) }
                                .lineupFlatButton()
                                .frame(width: 265)
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
                            Link(destination: trailers[index].1) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(LineupStyle.surface)
                                        LineupArtView(url: trailers[index].2
                                            ?? media.backdropURL(for: subject), width: 260) { loaded in
                                            if let image = loaded {
                                                image.resizable().scaledToFill()
                                            }
                                        }
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 24, weight: .bold))
                                            .shadow(radius: 8)
                                    }
                                    .frame(width: 260, height: 146)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(trailers[index].0).font(.inter(.subheadline, .semibold))
                                        .lineLimit(1)
                                }
                                .frame(width: 260, alignment: .leading)
                            }
                            .lineupFlatButton()
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
            }
        }
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
                                    LineupArtView(url: media.personImageURL(for: person), width: 112) { loaded in
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
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(related) { title in
                            NavigationLink(destination: MediaBrowseDestination(item: title)) {
                                MediaItemCard(item: title, shape: .poster)
                                    .frame(width: 145)
                            }
                            .lineupFlatButton()
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
            }
        }
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
        favorite = (loaded ?? item).isFavorite
        watched = (loaded ?? item).isPlayed
        let detailedItem = subject
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
            nextUp = up
            await loadSeason(seasonList.first { $0.indexNumber == up?.parentIndexNumber } ?? seasonList[0])
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

/// An episode card says which episode it is and what happens in it, so a viewer
/// picks by the description rather than by guessing from a still.
private struct MediaEpisodeCard: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.isFocused) private var focused
    let episode: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if episode.isPlayed {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(LineupStyle.background)
                            .frame(width: 26, height: 26)
                            .background(LineupStyle.lightPurple, in: Circle())
                            .padding(8)
                    }
                }
            if let label = episode.episodeLabel {
                Text(label).font(.inter(.caption, .semibold))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
            }
            Text(episode.name).font(.inter(.subheadline, .bold)).lineLimit(2)
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview).font(.inter(.caption)).lineLimit(3)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
            }
            if !footer.isEmpty {
                Text(footer).font(.inter(.caption2))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(LineupStyle.lightPurple)
        .focusLift(focused, scale: LineupStyle.cardLift)
    }

    private var footer: String {
        [episode.formattedAirDate, episode.formattedRuntime]
            .compactMap { $0 }.joined(separator: "  \u{00B7}  ")
    }
}

private struct MediaPlayableCard: View {
    let item: MediaItem
    var shape: MediaArtShape = .poster
    @State private var choosingSource = false

    var body: some View {
        #if os(tvOS)
        TVSelectable(action: { choosingSource = true }) { MediaItemCard(item: item, shape: shape) }
            .fullScreenCover(isPresented: $choosingSource) {
                MediaSourcePicker(item: item)
            }
        #else
        Button { choosingSource = true } label: { MediaItemCard(item: item, shape: shape) }
            .lineupFlatButton()
            .sheet(isPresented: $choosingSource) {
                MediaSourcePicker(item: item)
            }
        #endif
    }
}

private struct MediaSourcePicker: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var sources: [MediaPlaybackSource] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedSource: MediaPlaybackSource?
    @State private var providerFilter: String?

    // Sources in the order the server ranked their best result, so the chip
    // row reads the same way the list below it does.
    private var providers: [String] {
        var seen: Set<String> = []
        return sources.map(\.provider).filter { seen.insert($0).inserted }
    }

    private var visibleSources: [MediaPlaybackSource] {
        guard let providerFilter else { return sources }
        return sources.filter { $0.provider == providerFilter }
    }

    var body: some View {
        #if os(tvOS)
        // No NavigationStack: its bar is what drew the oversized title and the
        // Close button, and a sheet drew the card around them. The remote's
        // Menu button is how a viewer leaves a screen on this platform.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SELECT A STREAM").font(.inter(12, .heavy)).tracking(1.6)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
                Text(item.name).font(.inter(22, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, horizontalPadding).padding(.top, 36).padding(.bottom, 18)
            results
        }
        // A row left to its own devices runs the full width of a television,
        // which is what made every result read as a stretched strip. The whole
        // screen is held to one column instead, so the rows are boxes and the
        // eyebrow above them still lines up with their left edge.
        .frame(maxWidth: columnWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        .onExitCommand { dismiss() }
        .task(id: item.id) { await loadSources() }
        .fullScreenCover(item: $selectedSource) { source in playback(for: source) }
        #else
        NavigationStack {
            results
        }
        .task(id: item.id) { await loadSources() }
        .fullScreenCover(item: $selectedSource) { source in playback(for: source) }
        #endif
    }

    private var results: some View {
        Group {
                if loading {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Finding the best streams…").font(.inter(.headline))
                        Text("Looking for playable versions of \(item.name).")
                            .font(.inter(.subheadline)).foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    }
                    .mediaFocusAnchor()
                } else if let error {
                    ContentUnavailableView("Streams Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                        .mediaFocusAnchor()
                } else if sources.isEmpty {
                    ContentUnavailableView("No Streams Found", systemImage: "play.slash",
                        description: Text("Your server returned no playable version of this title."))
                        .mediaFocusAnchor()
                } else {
                    VStack(spacing: 0) {
                        // Results arrive interleaved from every source the server
                        // reports, and a viewer who trusts one wants only its rows.
                        if providers.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    providerChip(title: "All", count: sources.count, provider: nil)
                                    ForEach(providers, id: \.self) { provider in
                                        providerChip(title: provider,
                                            count: sources.filter { $0.provider == provider }.count,
                                            provider: provider)
                                    }
                                }
                                .padding(.horizontal, horizontalPadding).padding(.vertical, 12)
                            }
                            .lineupFocusRegion()
                        }
                        ScrollView {
                            // Leading, because a row is as wide as its text
                            // now: centred, the ragged edge would be on both
                            // sides instead of neither.
                            LazyVStack(alignment: .leading, spacing: rowSpacing) {
                                ForEach(visibleSources) { source in
                                    #if os(tvOS)
                                    TVSelectable(scale: LineupStyle.cardLift, fill: LineupStyle.focused,
                                        fillRadius: 14, action: { selectedSource = source }) {
                                        MediaSourceRow(source: source)
                                    }
                                    #else
                                    Button { selectedSource = source } label: {
                                        MediaSourceRow(source: source)
                                    }
                                    .lineupFlatButton()
                                    #endif
                                }
                            }
                            .padding(.horizontal, horizontalPadding).padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .lineupFocusRegion()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LineupStyle.background.ignoresSafeArea())
            .foregroundStyle(LineupStyle.lightPurple)
            #if !os(tvOS)
            .navigationTitle(item.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: dismiss.callAsFunction) }
            }
            #endif
    }

    private func loadSources() async {
        loading = true
        providerFilter = nil
        do { sources = try await media.playbackSources(for: item); error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
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

    @ViewBuilder
    private func playback(for source: MediaPlaybackSource) -> some View {
        if let url = media.playbackURL(for: item, source: source) {
            #if os(tvOS)
            PlayerView(urls: [url], title: item.name, isLive: false)
            #else
            MobilePlayerView(name: item.name, urls: [url], isLive: false,
                             sourceBitrate: source.formattedBitrate,
                             sourceQuality: source.quality,
                             synopsis: playerSynopsis)
            #endif
        } else {
            ContentUnavailableView("Playback Unavailable", systemImage: "play.slash")
        }
    }

    private func providerChip(title: String, count: Int, provider: String?) -> some View {
        Button { providerFilter = provider } label: {
            MediaProviderChip(title: title, count: count, active: providerFilter == provider)
        }
        .lineupFlatButton()
    }

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        14
        #else
        10
        #endif
    }
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        // The sheet already insets itself. Another 70 on top of that left the
        // rows floating in a column down the middle of the screen.
        28
        #else
        16
        #endif
    }
    /// The measure the list is held to. A line of a release name wider than
    /// this is further than the eye tracks comfortably from a couch.
    private var columnWidth: CGFloat {
        #if os(tvOS)
        1180
        #else
        .infinity
        #endif
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
                .lineupLiquidGlass(shape,
                                   fallback: focused ? LineupStyle.focused : LineupStyle.surface,
                                   border: border)
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

private struct MediaProviderChip: View {
    @Environment(\.isFocused) private var focused
    let title: String
    let count: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.inter(.caption, .semibold)).lineLimit(1)
            Text("\(count)").font(.interDigits(.caption2, .bold)).opacity(0.55)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(active ? LineupStyle.background : LineupStyle.lightPurple)
        .background(active ? LineupStyle.lightPurple
            : (focused ? LineupStyle.focused : LineupStyle.surface), in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1))
        .scaleEffect(focused ? LineupStyle.controlLift : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }

    // Constant: the chip shows whether it is active, not whether it is focused.
    private var border: Color { active ? .clear : LineupStyle.line }
}

private struct MediaSourceRow: View {
    let source: MediaPlaybackSource

    var body: some View {
        // Everything in one column. Spread across a television the old
        // three-column row put the provider a screen away from the title it
        // belonged to, and left each result a thin strip a few pixels tall.
        // Stacked, a result is a block of lines the eye reads straight down.
        VStack(alignment: .leading, spacing: lineSpacing) {
            HStack(alignment: .top, spacing: 12) {
                // Fixed width and a single line, so 1080p reads as a rank marker
                // and can never wrap into a stack of digits the way it used to.
                Text(source.quality ?? "SD")
                    .font(.interDigits(qualitySize, .heavy))
                    .lineLimit(1).fixedSize()
                    .frame(width: qualityWidth, height: qualityHeight)
                    .background(accent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(source.releaseName)
                    .font(.inter(titleSize, .semibold))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // One quiet line each. Pills inside a pill inside a card was the
            // cheap part; the words carry themselves.
            if !source.badges.isEmpty {
                Text(source.badges.joined(separator: "  \u{00B7}  "))
                    .font(.inter(badgeSize, .medium))
                    .foregroundStyle(accent.opacity(0.74))
                    .lineLimit(1).truncationMode(.tail)
            }
            if !source.facts.isEmpty {
                Text(source.facts.joined(separator: "  \u{00B7}  "))
                    .font(.interDigits(factSize))
                    .foregroundStyle(accent.opacity(0.5))
                    .lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 8) {
                Text(source.provider.uppercased())
                    .font(.inter(markSize, .heavy)).tracking(1.1)
                    .lineLimit(1)
                if let score = source.score {
                    Text("\u{00B7}").font(.inter(markSize, .heavy))
                    Text("RANK " + (score >= 0 ? "+\(score)" : "\(score)"))
                        .font(.inter(markSize, .heavy)).tracking(1.1)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(accent.opacity(0.5))
        }
        .padding(.horizontal, insetH).padding(.vertical, insetV)
        // A television row is as wide as the words in it. Held to the column
        // width it ran on past the end of a release name -- half an empty card
        // on every row, and the whole of it lit when the row took focus.
        .frame(maxWidth: rowWidth, alignment: .leading)
        .background { plate }
        .foregroundStyle(accent)
        .accessibilityElement(children: .combine)
    }

    /// Nothing is drawn around a result on a television: the list floats on the
    /// background and the focused row is the only one wearing a fill. A phone
    /// keeps its card, where a tap target needs an edge to aim at.
    @ViewBuilder private var plate: some View {
        #if !os(tvOS)
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LineupStyle.surface)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LineupStyle.line, lineWidth: 1))
        #endif
    }

    #if os(tvOS)
    /// nil lets the row size to its content; a phone card still spans its list.
    private var rowWidth: CGFloat? { nil }
    private var lineSpacing: CGFloat { 13 }
    private var titleSize: CGFloat { 28 }
    // The three lines under the release carry the detail somebody is actually
    // choosing between -- codec, size, indexer -- and at a footnote's size a
    // television turns them into texture. They keep their order below the
    // title without being small enough to squint at.
    private var badgeSize: CGFloat { 23 }
    private var factSize: CGFloat { 21 }
    private var markSize: CGFloat { 20 }
    private var qualitySize: CGFloat { 20 }
    private var qualityWidth: CGFloat { 90 }
    private var qualityHeight: CGFloat { 40 }
    private var insetH: CGFloat { 26 }
    private var insetV: CGFloat { 24 }
    #else
    private var rowWidth: CGFloat? { .infinity }
    private var lineSpacing: CGFloat { 8 }
    private var titleSize: CGFloat { 16 }
    private var badgeSize: CGFloat { 12 }
    private var factSize: CGFloat { 11 }
    private var markSize: CGFloat { 11 }
    private var qualitySize: CGFloat { 13 }
    private var qualityWidth: CGFloat { 62 }
    private var qualityHeight: CGFloat { 26 }
    private var insetH: CGFloat { 20 }
    private var insetV: CGFloat { 18 }
    #endif

    private var accent: Color { LineupStyle.lightPurple }

    private func badge(_ text: String) -> some View {
        Text(text).font(.inter(.caption2, .bold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(accent.opacity(0.85))
            .background(accent.opacity(0.11), in: Capsule())
    }
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

/// An episode's primary image is a 16:9 still and a movie's is a portrait poster.
/// Choosing per item is what left a shelf ragged, so a screen picks one shape
/// from what it is showing and every card on it is cut to that shape.
private enum MediaArtShape {
    case poster
    case still

    var ratio: CGFloat { self == .poster ? 2 / 3 : 16 / 9 }

    static func forItems(_ items: [MediaItem]) -> MediaArtShape {
        if items.isEmpty { return .poster }
        return items.contains(where: { $0.type != "Episode" }) ? .poster : .still
    }
}

private struct MediaItemCard: View {
    @EnvironmentObject private var media: MediaLibrary
    @Environment(\.isFocused) private var focused
    let item: MediaItem
    var shape: MediaArtShape = .poster

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                        LineupArtView(url: media.imageURL(for: item), width: artWidth) { loaded in
                            if let image = loaded { image.resizable().scaledToFill() }
                            else { Image(systemName: item.isFolder ? "rectangle.stack.fill" : "film.fill").font(.largeTitle) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
            // Two lines are held whether or not the title needs them, so the line
            // under it lands on the same baseline across a row.
            Text(item.name).font(titleFont).lineLimit(2, reservesSpace: true)
            HStack(spacing: 7) {
                Text(item.type.uppercased())
                if let year = item.productionYear { Text("· \(String(year))") }
                if let count = item.childCount { Text("· \(count)") }
            }
            .font(.inter(.caption2, .medium)).foregroundStyle(LineupStyle.lightPurple.opacity(0.58))
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .focusLift(focused, scale: LineupStyle.cardLift)
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
    private var cardRadius: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .inter(.headline)
        #else
        .inter(.subheadline, .semibold)
        #endif
    }
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
                    TextField("Server URL", text: $server)
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
                Section {
                    Button(media.isLoading ? "Connecting…" : "Connect") {
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
                    .disabled(media.isLoading
                        || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Supports Jellyfin, Nullfin and other Jellyfin-compatible servers. Leave the password blank for a user that has none. Access tokens are stored securely in this device’s Keychain.")
                }
                if let error = media.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Media Server")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .disabled(media.isLoading)
        }
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
