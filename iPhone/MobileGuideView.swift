import SwiftUI
import UIKit

/// What the Guide lists. One at a time: favorites, recently watched, every
/// channel, or one category.
///
/// These were two switches and a category picker, and the switches narrowed
/// whatever category was picked, so Favorites with a category ticked showed
/// only the favorites in that category -- usually none -- and favorites
/// showed in full only with All channels ticked as well.
enum MobileGuideFilter: Hashable {
    case favorites
    case recents
    case all
    case category(String)

    var categoryID: String? {
        if case .category(let id) = self { return id }
        return nil
    }
}

/// A programme picked from the catch-up list, played once the list closes.
private struct PendingRecording {
    let stream: XtreamStream
    let programme: CatchUpProgramme
}

struct MobileGuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileUsesLineupNavigation) private var usesLineupNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var showsSearch = false
    /// The TV Guide's options, dropped from the bar's ellipsis.
    @State private var optionsOpen = false
    @FocusState private var searchFocused: Bool
    /// What the viewer picked; until they pick, `filter` decides.
    @State private var chosenFilter: MobileGuideFilter?
    @State private var window = MobileGuideWindow(now: .now)
    @State private var horizontalOffset: CGFloat = 0
    /// How much of the channel list the tab bar covers, measured on screen.
    @State private var listBottomInset: CGFloat = 0
    @State private var resetPosition = UUID()
    @StateObject private var playbackSlot = MobilePlaybackSlot()
    /// A new selection gets a new controller; see `MobilePlaybackSlot`.
    private var playback: MobilePlaybackController {
        get { playbackSlot.controller }
        nonmutating set { playbackSlot.controller = newValue }
    }
    @State private var selectedStream: XtreamStream?
    @State private var expanded = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var reorderingFavorites = false
    /// The channel before the one in the player, for Last Channel.
    @State private var previousChannel: XtreamStream?
    /// The channel just tuned to, named over the picture for a moment.
    @State private var channelBanner: MobileChannelBannerInfo?
    @State private var bannerTask: Task<Void, Never>?
    /// The game an alert sent the player to, which a further alert about it
    /// would be no news of.
    @State private var watchingGame: SportsGame?
    /// The channel whose past programmes are listed, and the one picked from
    /// the list, played once the list has gone.
    @State private var catchUpChannel: XtreamStream?
    @State private var pendingRecording: PendingRecording?
    /// Lineup's own match for the game being picked for. Resolved once when the
    /// picker appears: `verifiedStream` revalidates against the guide, which is
    /// far too costly to run per row on every redraw.
    @State private var recommendedStreamID: Int?
    @ScaledMetric(relativeTo: .caption) private var rowHeight = 68.0
    var game: SportsGame? = nil
    var isActive = true
    var onFullscreenChange: (Bool) -> Void = { _ in }
    let onPlay: (XtreamStream) -> Void
    private let logoWidth: CGFloat = 80
    private var cardHeight: CGFloat { rowHeight - 6 }

    /// The phone is on its side. Every iPhone has a compact height there and
    /// only there.
    private var sideways: Bool { verticalSizeClass == .compact }

    /// The player fills the screen when asked to, and whenever the phone is
    /// on its side -- worked out from the orientation, so it happens inside
    /// the rotation rather than a beat after it, and undoes itself upright.
    ///
    /// Only on this tab: a player kept for Picture in Picture while another
    /// tab is open must not take the screen from it when the phone turns.
    private var fillsScreen: Bool { isActive && selectedStream != nil && (expanded || sideways) }

    /// Favorites, until the viewer picks something else -- or every channel
    /// while there are no favorites yet, or when picking for a game.
    private var filter: MobileGuideFilter {
        if let chosenFilter { return chosenFilter }
        return game == nil && !library.favoriteStreamOrder.isEmpty ? .favorites : .all
    }

    /// A search looks through every channel, whatever the Guide is showing.
    private var searching: Bool { !query.isEmpty }

    private var channels: [XtreamStream] {
        let listed = library.guideStreams(categoryID: searching ? nil : filter.categoryID,
                                          favoritesOnly: !searching && filter == .favorites,
                                          query: query, recentsOnly: !searching && filter == .recents)
        // Only when picking a channel for a game. The Guide's own ordering —
        // favorites, then the provider's order — is left exactly as it was.
        guard game != nil, let recommendedStreamID,
              let index = listed.firstIndex(where: { $0.id == recommendedStreamID }) else { return listed }
        var reordered = listed
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }
    private var title: String {
        if game != nil { return "Choose a channel" }
        if searching { return "Search" }
        switch filter {
        case .favorites: return "Favorites"
        case .recents: return "Recent"
        case .all: return "TV Guide"
        case .category(let id): return library.categories.first { $0.id == id }?.categoryName ?? "TV Guide"
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                let showsMetadata = viewport.size.height > 400
                let metadataHeight: CGFloat = showsMetadata ? 106 : 0
                let videoHeight = min(viewport.size.width * 9 / 16, max(80, viewport.size.height * 0.52 - metadataHeight))
                let fullHeight = MobilePlayerLayout.fullscreenHeight(containerHeight: viewport.size.height,
                                                                    safeAreaTop: viewport.safeAreaInsets.top,
                                                                    safeAreaBottom: viewport.safeAreaInsets.bottom)
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        if selectedStream != nil {
                            Color.clear.frame(height: videoHeight + metadataHeight)
                        }
                        if let game {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(game.awayTeam) vs. \(game.homeTeam)").font(.inter(.subheadline, .bold))
                                Text("Select your preferred channel.")
                                    .font(.inter(.caption)).foregroundStyle(.secondary)
                                Text(game.broadcast.isEmpty ? "Network unavailable" : game.broadcast)
                                    .font(.inter(.caption2)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                        if channels.isEmpty && filter == .favorites && !searching {
                            LineupUnavailableView("No favorites", systemImage: "star",
                                description: Text("Touch and hold a channel to add it to your favorites, or pick All channels from the menu."))
                        } else if channels.isEmpty {
                            LineupUnavailableView("No channels", systemImage: "tv",
                                description: Text("Try another category or search, or refresh your guide."))
                        } else if isActive {
                            TimelineView(.periodic(from: .now, by: 5)) { clock in
                                guide(now: clock.date)
                                    .onChange(of: clock.date) { _, now in
                                        // Keep live in view while preserving deliberate future browsing.
                                        if horizontalOffset < 1 && window.isStale(at: now) {
                                            window = MobileGuideWindow(now: now)
                                        }
                                    }
                            }
                        } else {
                            // TabView keeps the Guide mounted while another tab
                            // is visible. Preserve its rows and scroll state,
                            // but do not wake and rebuild the hidden grid every
                            // five seconds.
                            guide(now: window.anchor)
                        }
                    }
                    .allowsHitTesting(!fillsScreen)
                    .accessibilityHidden(fillsScreen)
                    if let stream = selectedStream {
                        TimelineView(.periodic(from: .now, by: 5)) { clock in
                            MobileGuidePlayer(controller: playback, stream: stream,
                                program: library.guidePrograms(for: stream).first { $0.start <= clock.date && clock.date < $0.end },
                                expanded: fillsScreen, showsMetadata: showsMetadata,
                                videoHeight: fillsScreen ? fullHeight : videoHeight,
                                screenInsets: viewport.safeAreaInsets,
                                onClose: closePlayer, onExpand: sideways ? nil : { setExpanded(!expanded) },
                                onRetry: { playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id) },
                                // Up and down the list on screen, whatever it
                                // is showing: favorites, a category, a search.
                                onStepChannel: channelStepper(around: stream),
                                lastChannelName: lastChannel?.name,
                                onLastChannel: { if let last = lastChannel { tune(last) } },
                                channelBanner: channelBanner,
                                watchingGameID: watchingGame?.id,
                                onWatchGame: { watchGame($0) })
                                .frame(height: fillsScreen ? fullHeight : videoHeight + metadataHeight, alignment: .top)
                                .background(LineupStyle.background)
                        }
                        // The player is the one thing that reaches past the
                        // chrome, so it claims the whole screen itself rather
                        // than waiting for the guide around it to get out of the
                        // way first. Its position and size stay identical
                        // whether or not the bars have finished hiding.
                        .ignoresSafeArea(fillsScreen ? .all : [], edges: .all)
                        .id(ObjectIdentifier(playback))
                        .modifier(MobileDismissGesture(
                            enabled: fillsScreen,
                            onBeginExit: { playback.freezePictureForExit() },
                            onDismiss: closePlayer))
                    }
                }
            }
            .background(LineupStyle.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsSearch && !fillsScreen {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Search channels", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($searchFocused)
                            .onSubmit { searchFocused = false }
                            .task { searchFocused = true }
                        if !query.isEmpty {
                            Button {
                                query = ""
                                searchFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.leading, 14).padding(.trailing, 4)
                    .frame(minHeight: 44)
                    .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: LineupStyle.compactRadius, style: .continuous))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(LineupStyle.background)
                }
            }
            .overlay {
                MobileDropdownLayer(isPresented: optionsOpen && !fillsScreen, title: "TV Guide",
                                    symbol: "list.bullet.rectangle", sections: optionsSections) {
                    setOptions(false)
                }
            }
            .toolbar {
                if game != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.buttonStyle(LineupBarButtonStyle()) }
                }
                ToolbarItem(placement: .primaryAction) {
                    MobileDropdownButton(isOpen: optionsOpen, label: "TV Guide options") {
                        setOptions(!optionsOpen)
                    }
                }
            }
            .toolbar(fillsScreen ? .hidden : .visible, for: .navigationBar)
            .toolbar(fillsScreen || usesLineupNavigation ? .hidden : .visible, for: .tabBar)
            .statusBarHidden(fillsScreen)
            .persistentSystemOverlays(fillsScreen ? .hidden : .automatic)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { returnToNow() }
                // Backgrounding no longer stops the stream; MobileBackgroundPolicy
                // decides whether this transition touches playback at all.
                if selectedStream != nil { playback.handleScenePhase(active: phase == .active) }
            }
            .onChange(of: playback.isPlaying) { _, playing in
                // Genuinely playing, not merely selected.
                if playing, let stream = selectedStream { library.recordRecentChannel(stream) }
            }
            .onChange(of: fillsScreen) { _, value in
                if value { searchFocused = false; optionsOpen = false }
                onFullscreenChange(value)
            }
            .onChange(of: sideways) { _, value in
                // Full screen by hand, then turned on its side, comes back
                // upright as the guide's own player, not as full screen.
                if value { expanded = false }
            }
            .onChange(of: isActive) { _, active in
                // Leaving the Guide tab still tears the player down — except
                // while the PiP window is showing this stream, which the viewer
                // asked to keep watching.
                if !active {
                    searchFocused = false
                    optionsOpen = false
                    if !playback.pictureInPictureActive { closePlayer() }
                } else { returnToNow() }
            }
            .onAppear {
                returnToNow()
                if let game { recommendedStreamID = library.verifiedStream(for: game)?.id }
            }
            // Played once the list has gone, so the player doesn't open
            // under a sheet that is still closing.
            .sheet(item: $catchUpChannel, onDismiss: {
                guard let pending = pendingRecording else { return }
                pendingRecording = nil
                openRecording(pending.stream, programme: pending.programme)
            }) { stream in
                MobileCatchUpSheet(stream: stream) { programme in
                    pendingRecording = PendingRecording(stream: stream, programme: programme)
                    catchUpChannel = nil
                }
                .environmentObject(library)
                .tint(LineupStyle.highlight)
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $reorderingFavorites) {
                FavoritesOrderView()
                    .environmentObject(library)
                    .tint(LineupStyle.highlight)
                    .preferredColorScheme(.dark)
            }
        }
    }

    /// One of the Guide's choices, ticked when it is the one shown. Picking
    /// it replaces whatever was ticked; picking the ticked one again keeps it.
    /// Touch and hold on a channel: its place in the favorites, and for a
    /// channel the provider records, what is on now from its start and what
    /// it showed before.
    private func channelMenuItems(_ stream: XtreamStream) -> [MobileMenuItem] {
        var items: [MobileMenuItem] = []
        if library.isFavorite(stream) {
            if filter == .favorites && !searching {
                items.append(MobileMenuItem("Move Up", symbol: "arrow.up",
                                            isEnabled: library.canMoveFavorite(stream, offset: -1)) {
                    library.moveFavorite(stream, offset: -1)
                })
                items.append(MobileMenuItem("Move Down", symbol: "arrow.down",
                                            isEnabled: library.canMoveFavorite(stream, offset: 1)) {
                    library.moveFavorite(stream, offset: 1)
                })
            }
            items.append(MobileMenuItem("Reorder Favorites", symbol: "arrow.up.arrow.down") {
                reorderingFavorites = true
            })
            items.append(MobileMenuItem("Remove Favorite", symbol: "star.slash", isDestructive: true) {
                library.removeFavorite(stream)
            })
        } else {
            items.append(MobileMenuItem("Add Favorite", symbol: "star") { library.addFavorite(stream) })
        }
        if stream.hasCatchUp && game == nil {
            items.append(MobileMenuItem("Start Over", symbol: "backward.end") {
                openRecording(stream, programme: nil)
            })
            items.append(MobileMenuItem("Catch Up", symbol: "clock.arrow.circlepath") { catchUpChannel = stream })
        }
        return items
    }

    private func setOptions(_ open: Bool) {
        guard optionsOpen != open else { return }
        if open { searchFocused = false }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
            optionsOpen = open
        }
    }

    /// What the TV Guide's dropdown offers: getting about, which channels the
    /// guide lists -- the categories a list of their own inside it -- and a
    /// refresh.
    private var optionsSections: [MobileMenuSection] {
        let categories = library.categories.map { category in
            MobileMenuItem(category.categoryName, id: "category-\(category.id)",
                           isSelected: filter == .category(category.id)) {
                chosenFilter = .category(category.id)
            }
        }
        let inCategory: Bool = { if case .category = filter { return true } else { return false } }()
        return [
            MobileMenuSection(id: "move", items: [
                MobileMenuItem("Return to Now", symbol: "clock") { returnToNow() },
                MobileMenuItem(showsSearch ? "Close Search" : "Search Channels",
                               symbol: showsSearch ? "xmark" : "magnifyingglass") {
                    if showsSearch { closeSearch() } else { showsSearch = true }
                }
            ]),
            MobileMenuSection(id: "channels", items: [
                MobileMenuItem("Favorites", symbol: "star", isSelected: filter == .favorites) {
                    chosenFilter = .favorites
                },
                MobileMenuItem("Recently Watched", symbol: "clock.arrow.circlepath",
                               isSelected: filter == .recents,
                               isEnabled: !library.recentStreams.isEmpty) {
                    chosenFilter = .recents
                },
                MobileMenuItem("All Channels", symbol: "tv", isSelected: filter == .all) {
                    chosenFilter = .all
                },
                MobileMenuItem("Categories", symbol: "square.stack", isSelected: inCategory,
                               isEnabled: !categories.isEmpty,
                               children: [MobileMenuSection(id: "categories", items: categories)])
            ]),
            MobileMenuSection(id: "refresh", items: [
                MobileMenuItem("Refresh Guide", symbol: "arrow.clockwise",
                               isEnabled: !library.channelsAreSyncing) {
                    Task { await library.reload() }
                }
            ])
        ]
    }

    private func selectChannel(_ stream: XtreamStream) {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        // The manual game picker still returns its selection to the Live screen.
        guard game == nil else { onPlay(stream); return }
        guard selectedStream?.id != stream.id else { return }
        // A new selection gets a new VLC session and surface. A stopped renderer
        // from an earlier tab visit must never become the next channel's output.
        if let current = selectedStream { previousChannel = current }
        watchingGame = nil
        playback.shutdown()
        playback = MobilePlaybackController()
        selectedStream = stream
        playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id)
        playback.loadCatchUpSource(for: stream, from: library)
    }

    /// A recording rather than the channel live: a programme from the past,
    /// or with nil the one on now from its start. Full screen, as something
    /// chosen to sit and watch.
    private func openRecording(_ stream: XtreamStream, programme: CatchUpProgramme?) {
        if let current = selectedStream, current.id != stream.id { previousChannel = current }
        watchingGame = nil
        if selectedStream == nil {
            // A fresh player for a fresh opening, as a new selection gets.
            playback.shutdown()
            playback = MobilePlaybackController()
        }
        selectedStream = stream
        setExpanded(true)
        let controller = playback
        Task { await controller.openRecording(of: stream, programme: programme, from: library) }
    }

    /// The channel Last Channel goes back to: the one played before this,
    /// else the last one watched anywhere.
    private var lastChannel: XtreamStream? {
        guard let current = selectedStream else { return nil }
        if let previousChannel, previousChannel.id != current.id { return previousChannel }
        return library.recentStreams.first { $0.id != current.id }
    }

    /// Steps along the list on screen from the channel playing, round from
    /// the end to the start. Nil while picking a channel for a game, or with
    /// nothing else in the list to step to.
    private func channelStepper(around stream: XtreamStream) -> ((Int) -> Void)? {
        guard game == nil else { return nil }
        let lineup = channels
        guard lineup.count > 1 else { return nil }
        return { step in
            let index = lineup.firstIndex { $0.id == stream.id }
            let next = index.map { ($0 + step + lineup.count) % lineup.count } ?? (step > 0 ? 0 : lineup.count - 1)
            tune(lineup[next])
        }
    }

    /// Changes channel on the same player, so full screen stays full screen,
    /// and names the new channel over the picture for a moment.
    private func tune(_ stream: XtreamStream, for game: SportsGame? = nil) {
        guard let current = selectedStream, current.id != stream.id || game != nil else { return }
        if current.id != stream.id { previousChannel = current }
        watchingGame = game
        selectedStream = stream
        playback.failover = nil
        playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id)
        playback.loadCatchUpSource(for: stream, from: library)
        let info = MobileChannelBannerInfo(
            stream: stream,
            program: library.guidePrograms(for: stream).normalizedEPG().first { $0.isLive })
        channelBanner = info
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if channelBanner == info { channelBanner = nil }
        }
    }

    /// One of the viewer's teams' games, from an alert, on its channel. A
    /// game with no channel yet is left for the Live tab, where one can be
    /// chosen for it.
    private func watchGame(_ game: SportsGame) {
        GameAlertCenter.shared.dismiss()
        guard let stream = library.resolvedStream(for: game) else { return }
        tune(stream, for: game)
    }

    /// Expanding moves the video, the guide behind it, the navigation bar, the
    /// tab bar and the status bar. Driving all of it from one animated change is
    /// what makes it read as a single motion instead of the video jumping first
    /// and the chrome catching up afterwards.
    private func setExpanded(_ value: Bool) {
        let fills = isActive && selectedStream != nil && (value || sideways)
        guard !reduceMotion else {
            expanded = value
            onFullscreenChange(fills)
            return
        }
        withAnimation(.smooth(duration: 0.34)) {
            expanded = value
            onFullscreenChange(fills)
        }
    }

    private func closePlayer() {
        guard selectedStream != nil else { return }
        playback.shutdown()
        selectedStream = nil
        expanded = false
    }

    private func closeSearch() {
        searchFocused = false
        showsSearch = false
        query = ""
    }

    private func returnToNow() {
        window = MobileGuideWindow(now: .now)
        horizontalOffset = 0
        resetPosition = UUID()
    }

    private func guide(now: Date) -> some View {
        GeometryReader { viewport in
            // One horizontal scroller moves every program row and the ruler together.
            // The nested vertical scroller moves logos and programs as a single row.
            // Counter-offset logo tiles keep the channel column frozen horizontally.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    ruler(now: now)
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(channels) { stream in
                                HStack(spacing: 0) {
                                    channelTile(stream)
                                        .offset(x: horizontalOffset).zIndex(2)
                                    programRow(stream, now: now, viewportWidth: viewport.size.width - logoWidth)
                                }.frame(height: rowHeight)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(MobileGuideScrollConfiguration(horizontal: false) { listBottomInset = $0 })
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                    // Room for the last channel to clear the floating tab bar
                    // is measured, not assumed: `MobileGuideScrollConfiguration`
                    // reports exactly the part of the list the bar covers, so
                    // the end bounces and settles with the last row flush above
                    // the bar, as the top settles on the first.
                    .contentMargins(.bottom, listBottomInset, for: .scrollContent)
                    .contentMargins(.bottom, listBottomInset, for: .scrollIndicators)
                    .frame(height: max(0, viewport.size.height - 40))
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable { await library.reload() }
                }
                .frame(width: logoWidth + window.width, height: viewport.size.height, alignment: .topLeading)
                .background(MobileGuideScrollConfiguration(horizontal: true))
                .background {
                    GeometryReader { position in
                        Color.clear.preference(key: GuideHorizontalPosition.self,
                            value: position.frame(in: .named("guideHorizontal")).minX)
                    }
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
            // Held clear of the sides rather than allowed to run under them.
            // In landscape the Dynamic Island eats into one edge, and the
            // frozen channel column lives against exactly that edge, so the
            // logos were disappearing behind it.
            .safeAreaPadding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: "guideHorizontal")
            .onPreferenceChange(GuideHorizontalPosition.self) { value in
                horizontalOffset = max(0, -value)
            }
            .id(resetPosition)
        }
    }

    private func ruler(now: Date) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("NOW").font(.inter(8, .bold)).tracking(1)
                Text(now, format: .dateTime.hour().minute())
                    .font(.interDigits(.caption2, .semibold))
            }
                .frame(width: logoWidth, height: 40)
                .background(LineupStyle.background)
                .offset(x: horizontalOffset).zIndex(2)
            ZStack(alignment: .topLeading) {
                ForEach(window.ticks, id: \.self) { date in
                    Text(date, format: .dateTime.hour().minute())
                        .font(.interDigits(.caption2, .semibold))
                        .padding(.leading, 7).frame(width: MobileGuideWindow.pointsPerSecond * 1800, height: 32, alignment: .leading)
                        .offset(x: window.x(date))
                }
            }.frame(width: window.width, height: 40, alignment: .topLeading)
        }
        .background(LineupStyle.background)
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
    }

    /// Lineup's verified match, shown only while picking a channel for a game.
    private func isRecommended(_ stream: XtreamStream) -> Bool {
        game != nil && stream.id == recommendedStreamID
    }

    private func channelTile(_ stream: XtreamStream) -> some View {
        Group {
            ZStack(alignment: .center) {
                LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: logoWidth) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit()
                            .frame(width: logoWidth - 16, height: min(42, cardHeight - 12), alignment: .center)
                    } else {
                        Text(stream.name).font(.inter(.caption2, .semibold)).lineLimit(3)
                            .multilineTextAlignment(.center).padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: logoWidth - 8, height: cardHeight)
            .overlay(alignment: .bottom) {
                if isRecommended(stream) {
                    Text("RECOMMENDED")
                        .font(.inter(7, .bold)).tracking(0.4)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(LineupStyle.highlight, in: Capsule())
                        .foregroundStyle(LineupStyle.onHighlight)
                        .padding(.bottom, 1)
                }
            }
            .overlay(alignment: .topLeading) {
                if library.isFavorite(stream) {
                    Image(systemName: "star.fill").font(.inter(.caption2))
                        .padding(4).background(LineupStyle.background.opacity(0.85), in: Circle())
                        .padding(3)
                }
            }
            .frame(width: logoWidth, height: rowHeight, alignment: .center)
            .contentShape(Rectangle())
            // The frozen column masks scrolling programs with the guide's base color.
            .background(LineupStyle.background)
        }
        .lineupHoldMenu(stream.name, symbol: "tv", press: .dim, items: { channelMenuItems(stream) }) {
            selectChannel(stream)
        }
        .accessibilityLabel("\(isRecommended(stream) ? "Recommended. " : "")Watch \(stream.name) live\(library.isFavorite(stream) ? ", favorite" : "")")
    }

    private func programRow(_ stream: XtreamStream, now: Date, viewportWidth: CGFloat) -> some View {
        let programs = library.guidePrograms(for: stream)
        let segments = window.segments(programs.map { (start: $0.start, end: $0.end) })
        return ZStack(alignment: .leading) {
            ForEach(segments) { segment in
                let program = segment.programIndex.map { programs[$0] }
                let cellX = window.x(segment.start)
                let width = max(1, window.x(segment.end) - cellX - 5)
                let textInset = min(max(0, horizontalOffset - cellX), max(0, width - 24))
                let live = program.map { $0.start <= now && now < $0.end } ?? false
                Button { selectChannel(stream) } label: {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(live ? LineupStyle.focused : LineupStyle.raised)
                        if program != nil, live {
                            // The app's progress bar along the foot of what is
                            // on now, its fill ending where the timeline says
                            // now is.
                            let played = min(width, max(0, window.x(now) - cellX))
                            let inset: CGFloat = 8
                            LineupProgressBar(value: Double((played - inset) / max(1, width - inset * 2)),
                                              height: 4)
                                .padding(.horizontal, inset)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .padding(.bottom, 5)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(program?.title ?? "No listing")
                                .font(.inter(.caption, program == nil ? .regular : .semibold)).lineLimit(2)
                                .foregroundStyle(program == nil ? LineupStyle.secondary : LineupStyle.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let program {
                                HStack(spacing: 5) {
                                    if live {
                                        MobileLiveDot()
                                        Text("LIVE")
                                    } else {
                                        Text(program.start, format: .dateTime.hour().minute())
                                    }
                                    if program.isNew == true { Text("NEW") }
                                }
                                .font(.inter(9, .medium))
                                .foregroundStyle(live ? LineupStyle.liveStatus : LineupStyle.secondary)
                                .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8)
                        // Clear of the bar along the foot of what is on now.
                        .padding(.bottom, live ? 8 : 0)
                        .frame(width: max(1, min(width - textInset, viewportWidth)), alignment: .leading)
                        .offset(x: textInset)
                    }
                    .frame(width: width, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            // Only what is on now is edged, in the accent; the
                            // rest are panels, told apart by their corners.
                            .strokeBorder(live ? LineupStyle.liveDot.opacity(0.45) : Color.clear, lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Watch \(stream.name) live. \(program?.title ?? "No guide information")")
                .offset(x: cellX)
            }
        }.frame(width: window.width, height: rowHeight, alignment: .leading)
    }
}

private struct GuideHorizontalPosition: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Favorites order drives the guide's channel order, so this list edits it directly:
/// drag a row to move a channel, swipe or tap the minus to drop it.
private struct FavoritesOrderView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let listed = library.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
        NavigationStack {
            Group {
                if listed.isEmpty {
                    LineupUnavailableView("No favorites", systemImage: "star",
                        description: Text("Touch and hold a channel in the guide to add it."))
                } else {
                    List {
                        ForEach(listed) { stream in
                            HStack(spacing: 12) {
                                LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 44) { loaded in
                                    if let image = loaded { image.resizable().scaledToFit() }
                                    else { Image(systemName: "tv").foregroundStyle(.secondary) }
                                }
                                .frame(width: 44, height: 30)
                                Text(stream.name).lineLimit(1)
                            }
                            .listRowBackground(LineupStyle.surface)
                        }
                        .onMove { source, destination in
                            library.moveFavorites(listed, fromOffsets: source, toOffset: destination)
                        }
                        .onDelete { offsets in
                            for stream in offsets.map({ listed[$0] }) { library.removeFavorite(stream) }
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                    .scrollContentBackground(.hidden)
                }
            }
            .background(LineupStyle.background)
            .navigationTitle("Favorites").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.buttonStyle(LineupBarButtonStyle(prominent: true)) }
            }
        }
    }
}

/// Navigation already positions this guide within the safe area. Its two nested
/// scrollers must not add that navigation inset again above the first channel.
/// The vertical one also reports how much of it the tab bar covers, which the
/// guide gives back to it as a bottom margin.
struct MobileGuideScrollConfiguration: UIViewRepresentable {
    let horizontal: Bool
    var onBottomOverlap: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.horizontal = horizontal
        probe.onBottomOverlap = onBottomOverlap
        DispatchQueue.main.async { [weak probe] in probe?.refresh() }
    }

    static func configure(_ scroll: UIScrollView, horizontal: Bool) {
        // Navigation already positions the guide inside the safe area, and
        // letting these scrollers adjust again put that inset in twice. The
        // cost is that they adjust for nothing else either, so the insets that
        // do matter -- the tab bar below, the island at the sides -- are
        // applied by the guide itself rather than left to the scroller.
        // Checked first: this runs on every layout of the list.
        if scroll.contentInsetAdjustmentBehavior != .never { scroll.contentInsetAdjustmentBehavior = .never }
        if !scroll.isDirectionalLockEnabled { scroll.isDirectionalLockEnabled = true }
        // Elastic horizontal overscroll would move the ruler beneath frozen logos.
        // Keep vertical elasticity for natural scrolling and pull-to-refresh.
        if horizontal && scroll.bounces { scroll.bounces = false }
    }

    /// The height of the list the tab bar covers: the room the last channel
    /// needs to come to rest right on top of the bar. It depends only on where
    /// the list and the bar are, never on the list's own insets, so applying it
    /// cannot change it.
    static func bottomOverlap(of scroll: UIScrollView) -> CGFloat {
        guard let window = scroll.window else { return 0 }
        let listBottom = scroll.convert(scroll.bounds, to: window).maxY
        let customTop = MobileLineupNavigationBoundary.find(in: window).map {
            $0.convert($0.bounds, to: window).minY
        }
        let barTop = customTop ?? tabBar(in: window).flatMap { bar -> CGFloat? in
            guard !bar.isHidden, bar.alpha > 0.01, bar.window != nil else { return nil }
            return bar.convert(bar.bounds, to: window).minY
        } ?? (window.bounds.maxY - window.safeAreaInsets.bottom)
        return max(0, (listBottom - barTop).rounded())
    }

    /// Sits behind the scroller's content and measures as soon as it is on
    /// screen and whenever the list lays out again. The inset used to be
    /// written straight onto the scroller after the fact, where SwiftUI's own
    /// updates could put it back, so the last channel sat under the bar until
    /// some later update happened to restore it. Now the measurement goes to
    /// SwiftUI, which applies it with the list's other margins and keeps it.
    final class Probe: UIView {
        var horizontal = false
        var onBottomOverlap: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refresh()
            // The first pass can come before the tab bar has its place.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            refresh()
        }

        var enclosingScrollView: UIScrollView? {
            var ancestor = superview
            while let candidate = ancestor {
                if let scroll = candidate as? UIScrollView { return scroll }
                ancestor = candidate.superview
            }
            return nil
        }

        func refresh() {
            guard window != nil, let scroll = enclosingScrollView else { return }
            MobileGuideScrollConfiguration.configure(scroll, horizontal: horizontal)
            guard !horizontal, let onBottomOverlap else { return }
            let overlap = MobileGuideScrollConfiguration.bottomOverlap(of: scroll)
            if let reported, abs(reported - overlap) <= 0.5 { return }
            reported = overlap
            // Never during SwiftUI's own update of this view.
            DispatchQueue.main.async { onBottomOverlap(overlap) }
        }
    }

    private static func tabBar(in window: UIWindow) -> UITabBar? {
        func search(_ controller: UIViewController?) -> UITabBar? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs.tabBar }
            for child in controller.children { if let bar = search(child) { return bar } }
            return search(controller.presentedViewController)
        }
        return search(window.rootViewController)
    }
}
