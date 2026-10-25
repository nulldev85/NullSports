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
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileUsesLineupNavigation) private var usesLineupNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MobileGuideViewMode.storageKey) private var guideViewModeValue = MobileGuideViewMode.defaultMode.rawValue
    @AppStorage(MobileGuideDefaultCategory.storageKey) private var defaultCategories = "{}"
    @AppStorage("lineup.mobile.guide.combinedDefaultProvider.v1") private var defaultProviderValue = ""
    @State private var query = ""
    @State private var showsSearch = false
    /// The TV Guide's options, dropped from the bar's ellipsis.
    @State private var optionsOpen = false
    /// Channel categories and favorites live in the centered selector pill.
    @State private var filterMenuOpen = false
    @FocusState private var searchFocused: Bool
    /// What the viewer picked; until they pick, `filter` decides.
    @State private var chosenFilter: MobileGuideFilter?
    @State private var window = MobileGuideWindow(now: .now)
    @State private var horizontalOffset: CGFloat = 0
    @State private var resetPosition = UUID()
    @StateObject private var playbackSlot = MobilePlaybackSlot()
    /// A new selection gets a new controller; see `MobilePlaybackSlot`.
    private var playback: MobilePlaybackController {
        get { playbackSlot.controller }
        nonmutating set { playbackSlot.controller = newValue }
    }
    @State private var selectedStream: XtreamStream?
    @State private var qualityTask: Task<Void, Never>?
    @State private var qualityRequest: UUID?
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
    /// Two channels at once, full screen.
    @State private var multiview: MobileMultiviewSession?
    /// The channel whose past programmes are listed, and the one picked from
    /// the list, played once the list has gone.
    @State private var catchUpChannel: XtreamStream?
    @State private var pendingRecording: PendingRecording?
    /// Lineup's own match for the game being picked for. Resolved once when the
    /// picker appears: `verifiedStream` revalidates against the guide, which is
    /// far too costly to run per row on every redraw.
    @State private var recommendedStreamID: Int?
    @ScaledMetric(relativeTo: .caption) private var rowHeight = 74.0
    @ScaledMetric(relativeTo: .caption2) private var providerInfoHeight = MobilePlayerLayout.inlineProviderHeight
    var game: SportsGame? = nil
    var isActive = true
    var onFullscreenChange: (Bool) -> Void = { _ in }
    let onPlay: (XtreamStream) -> Void
    private var cardHeight: CGFloat { rowHeight - 6 }

    /// The phone is on its side. Every iPhone has a compact height there and
    /// only there.
    private var sideways: Bool { verticalSizeClass == .compact }

    private var guideViewMode: MobileGuideViewMode { MobileGuideViewMode.restored(guideViewModeValue) }

    /// The player fills the screen when asked to, and whenever the phone is
    /// on its side -- worked out from the orientation, so it happens inside
    /// the rotation rather than a beat after it, and undoes itself upright.
    ///
    /// Only on this tab: a player kept for Picture in Picture while another
    /// tab is open must not take the screen from it when the phone turns.
    private var fillsScreen: Bool { isActive && selectedStream != nil && (expanded || sideways) }

    /// A provider's saved starting category, then the existing Favorites/All
    /// behavior. Manual choices last until the next entry to this tab.
    private var filter: MobileGuideFilter {
        if let chosenFilter { return chosenFilter }
        return MobileGuideDefaultCategory.initialFilter(for: defaultCategoryProfile, in: defaultCategories,
            categoryIDs: library.categories.map(\.id), hasFavorites: !library.favoriteStreamOrder.isEmpty,
            isGamePicker: game != nil)
    }

    private var defaultCategoryProfile: UUID? {
        if library.providerRoot !== library, let id = UUID(uuidString: defaultProviderValue),
           library.isProviderEnabled(id) { return id }
        return library.activeProfile?.id
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
            guidePresentations
        }
        .mobileTabHome(.guide) { restoreDefaultCategoryOnEntry() }
    }

    // Keep the view tree unchanged while giving Swift separate, bounded
    // expressions for layout, chrome, observations and presentations.
    private var guideViewport: some View {
        GeometryReader { viewport in
            let showsMetadata = viewport.size.height > 400
            let metadataHeight: CGFloat = showsMetadata ? 106 : 0
            let providerHeight: CGFloat = library.activeProfile == nil ? 0 : providerInfoHeight
            let timelineHeight: CGFloat = playback.catchUpSource != nil && playback.error == nil
                ? MobilePlayerLayout.inlineTimelineHeight : 0
            let videoHeight = min(viewport.size.width * 9 / 16, max(80, viewport.size.height * 0.52 - metadataHeight - providerHeight))
            let fullHeight = MobilePlayerLayout.fullscreenHeight(containerHeight: viewport.size.height,
                                                                safeAreaTop: viewport.safeAreaInsets.top,
                                                                safeAreaBottom: viewport.safeAreaInsets.bottom)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if selectedStream != nil {
                        Color.clear.frame(height: videoHeight + providerHeight + metadataHeight + timelineHeight)
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
                    if library.providerRoot.enabledProfiles.isEmpty {
                        LineupUnavailableView("No enabled providers", systemImage: "tv",
                            description: Text("Enable a service in Settings → IPTV."))
                    } else if channels.isEmpty && filter == .favorites && !searching {
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
                            providerName: library.providerName(for: stream),
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
                            .frame(height: fillsScreen ? fullHeight : videoHeight + providerHeight + metadataHeight + timelineHeight, alignment: .top)
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
    }

    private var guideNavigation: some View {
        guideViewport
            .background(Color.black)
            .navigationTitle(game == nil ? "" : title).navigationBarTitleDisplayMode(.inline)
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
                            .onSubmit {
                                if MobileGuideSearchPolicy.shouldCloseAfterSubmission(query) {
                                    closeSearch()
                                } else {
                                    searchFocused = false
                                }
                            }
                            .task { searchFocused = true }
                        Button {
                            if query.isEmpty {
                                closeSearch()
                            } else {
                                query = ""
                                searchFocused = true
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(query.isEmpty ? "Close search" : "Clear search")
                    }
                    .padding(.leading, 14).padding(.trailing, 4)
                    .frame(minHeight: 44)
                    .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: LineupStyle.compactRadius, style: .continuous))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(LineupStyle.background)
                }
            }
            .overlay {
                ZStack {
                    MobileDropdownLayer(isPresented: filterMenuOpen && !fillsScreen && game == nil && !showsSearch,
                                        title: "Channels", symbol: "tv", sections: filterSections,
                                        alignment: .top, horizontalInset: 0, backdropOpacity: 0.2,
                                        transitionAnchor: .top) {
                        setFilterMenu(false)
                    }
                    MobileDropdownLayer(isPresented: optionsOpen && !fillsScreen, title: "TV Guide",
                                        symbol: "list.bullet.rectangle", sections: optionsSections,
                                        alignment: .topLeading, transitionAnchor: .topLeading) {
                        setOptions(false)
                    }
                }
            }
            .toolbar {
                if game != nil {
                    LineupToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.buttonStyle(LineupBarButtonStyle()) }
                    LineupToolbarItem(placement: .primaryAction) {
                        MobileDropdownButton(isOpen: optionsOpen, label: "TV Guide options") {
                            setOptions(!optionsOpen)
                        }
                    }
                } else {
                    LineupToolbarItem(placement: .navigationBarLeading) {
                        MobileDropdownButton(isOpen: optionsOpen, label: "TV Guide options") {
                            setOptions(!optionsOpen)
                        }
                    }
                    LineupToolbarItem(placement: .principal) {
                        if showsSearch {
                            Text("Search").font(.inter(17, .heavy)).foregroundStyle(LineupStyle.text.opacity(0.82))
                        } else {
                            guideFilterButton
                        }
                    }
                }
            }
            .toolbar(fillsScreen ? .hidden : .visible, for: .navigationBar)
            .toolbar(fillsScreen || usesLineupNavigation ? .hidden : .visible, for: .tabBar)
            .statusBarHidden(fillsScreen)
            .persistentSystemOverlays(fillsScreen ? .hidden : .automatic)
    }

    private var guideObservations: some View {
        guideNavigation
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, qualityRequest != nil { cancelQualityCheck(); closePlayer() }
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
                if value { searchFocused = false; optionsOpen = false; filterMenuOpen = false }
                onFullscreenChange(value)
            }
            .onChange(of: sideways) { _, value in
                // Full screen by hand, then turned on its side, comes back
                // upright as the guide's own player, not as full screen.
                if value { expanded = false }
            }
            .onChange(of: guideViewModeValue) { _, _ in resetGuideScrollPosition() }
            .onChange(of: filter) { _, _ in resetGuideScrollPosition() }
            .onChange(of: query) { _, _ in resetGuideScrollPosition() }
            .onChange(of: library.favoriteStreamOrder) { _, _ in resetGuideScrollPosition() }
            .onChange(of: library.recentStreamOrder) { _, _ in resetGuideScrollPosition() }
            .onChange(of: library.streamsRevision) { _, _ in guideStreamsChanged() }
            .onChange(of: enabledProviderIDs) { _, _ in closeRetiredProvider() }
            .onChange(of: isActive) { _, active in
                if !active { cancelQualityCheck() }
                // Leaving the Guide tab still tears the player down — except
                // while the PiP window is showing this stream, which the viewer
                // asked to keep watching.
                if !active {
                    closeSearch()
                    optionsOpen = false
                    filterMenuOpen = false
                    if !playback.pictureInPictureActive { closePlayer() }
                } else {
                    restoreDefaultCategoryOnEntry()
                    returnToNow()
                }
            }
            .onAppear(perform: guideDidAppear)
    }

    private var guidePresentations: some View {
        guideObservations
            .overlay(alignment: .top) {
                if qualityRequest != nil { LiveQualityProgress { cancelQualityCheck(); closePlayer() } }
            }
            .onDisappear { cancelQualityCheck() }
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
                .environment(library)
                .tint(LineupStyle.highlight)
                .preferredColorScheme(.dark)
            }
            .fullScreenCover(item: $multiview) { session in
                MobileMultiviewView(session: session).environment(library)
            }
            .sheet(isPresented: $reorderingFavorites) {
                FavoritesOrderView()
                    .environment(library)
                    .tint(LineupStyle.highlight)
                    .preferredColorScheme(.dark)
            }
    }

    private var enabledProviderIDs: [UUID] { library.providerRoot.enabledProfiles.map(\.id) }

    private func guideDidAppear() {
        returnToNow()
        guard let game = game else { return }
        let recommended: XtreamStream? = library.verifiedStream(for: game)
        recommendedStreamID = recommended?.streamID
    }

    private func guideStreamsChanged() {
        if let stream = selectedStream, library.stream(withID: stream.id) == nil { closePlayer() }
        if let id = chosenFilter?.categoryID, !library.categories.contains(where: { $0.id == id }) { chosenFilter = nil }
        resetGuideScrollPosition()
    }

    private func closeRetiredProvider() {
        guard let stream = selectedStream else { return }
        let source = library.playbackSource(for: stream)
        let enabled: Bool = source.library.activeProfile.map { library.providerRoot.isProviderEnabled($0.id) } ?? false
        if library.stream(withID: stream.id) == nil || !enabled { closePlayer() }
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
        // Beside the channel already playing, rather than instead of it.
        if let current = selectedStream, current.id != stream.id, game == nil {
            items.append(MobileMenuItem("Watch Side by Side", symbol: "rectangle.split.2x1") {
                let tiles = [MobileMultiviewSession.Tile(stream: current, game: watchingGame),
                             MobileMultiviewSession.Tile(stream: stream, game: nil)]
                // Its connection goes before multiview opens two of its own.
                closePlayer()
                multiview = MobileMultiviewSession(tiles: tiles)
            })
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
        if open {
            if showsSearch && query.isEmpty { closeSearch() }
            else { searchFocused = false }
            filterMenuOpen = false
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
            optionsOpen = open
        }
    }

    private func setFilterMenu(_ open: Bool) {
        guard filterMenuOpen != open else { return }
        if open { optionsOpen = false }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
            filterMenuOpen = open
        }
    }

    private var guideFilterButton: some View {
        Button { setFilterMenu(!filterMenuOpen) } label: {
            HStack(spacing: 7) {
                Image(systemName: filterSymbol)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(LineupStyle.highlight)
                Text(filterTitle)
                    .font(.inter(14, .heavy))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(LineupStyle.text.opacity(0.78))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(LineupPanelStyle.quiet)
            }
            .padding(.horizontal, 13)
            .frame(height: 36)
            .frame(maxWidth: 220)
            .background(LineupPanelStyle.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Channel filter: \(filterTitle)")
        .accessibilityHint("Choose favorites, a category, or all channels")
    }

    private var filterTitle: String {
        switch filter {
        case .favorites: "Favorites"
        case .recents: "Recently Watched"
        case .all: "All Channels"
        case .category(let id): library.categories.first { $0.id == id }?.categoryName ?? "TV Guide"
        }
    }

    private var filterSymbol: String {
        switch filter {
        case .favorites: "star.fill"
        case .recents: "clock.arrow.circlepath"
        case .all: "tv"
        case .category: "square.stack.3d.up.fill"
        }
    }

    private var filterSections: [MobileMenuSection] {
        let currentFilter = filter
        let categories = library.categories.map { category in
            let source = library.categorySource(for: category.id)
            let defaultID = MobileGuideDefaultCategory.categoryID(for: source.profileID, in: defaultCategories)
            return MobileGuideCategoryMenu.item(for: category, isSelected: currentFilter == .category(category.id),
                isDefault: defaultID == source.categoryID, allowsDefault: game == nil && source.profileID != nil, select: {
                chosenFilter = .category(category.id)
            }, changeDefault: { categoryID in
                guard let profileID = source.profileID, library.isProviderEnabled(profileID), game == nil,
                      library.categories.contains(where: { $0.id == category.id }) else { return }
                defaultCategories = MobileGuideDefaultCategory.setting(categoryID == nil ? nil : source.categoryID, for: profileID, in: defaultCategories)
                defaultProviderValue = categoryID == nil ? "" : profileID.uuidString
                chosenFilter = nil
                setFilterMenu(false)
            })
        }
        let inCategory: Bool = { if case .category = currentFilter { return true } else { return false } }()
        return [
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
            ])
        ]
    }

    private func restoreDefaultCategoryOnEntry() {
        chosenFilter = MobileGuideDefaultCategory.selectionOnEntry(chosenFilter,
            for: defaultCategoryProfile, in: defaultCategories, isGamePicker: game != nil)
    }

    /// What the TV Guide's dropdown offers: getting about, which channels the
    /// guide displays, playback modes, and refresh actions. Channel filters
    /// belong to the centered selector on the main Guide, and remain in this
    /// menu while picking a channel for a sports event.
    private var optionsSections: [MobileMenuSection] {
        var sections = [
            MobileMenuSection(id: "view-mode", title: "View Mode", items: MobileGuideViewMode.allCases.map { mode in
                MobileMenuItem(mode.title, symbol: mode.symbol, id: "view-\(mode.rawValue)",
                               isSelected: guideViewMode == mode) {
                    guideViewModeValue = mode.rawValue
                }
            }),
            MobileMenuSection(id: "move", items: [
                MobileMenuItem("Return to Now", symbol: "clock") { returnToNow() },
                MobileMenuItem(showsSearch ? "Close Search" : "Search Channels",
                               symbol: showsSearch ? "xmark" : "magnifyingglass") {
                    if showsSearch { closeSearch() } else { showsSearch = true }
                }
            ])
        ]
        if game != nil { sections.append(contentsOf: filterSections) }
        sections.append(MobileMenuSection(id: "refresh", items: [
            MobileMenuItem("Refresh Guide", symbol: "arrow.clockwise",
                           isEnabled: !library.channelsAreSyncing) {
                Task { await library.reload() }
            }
        ]))
        return sections
    }

    private func selectChannel(_ stream: XtreamStream) {
        cancelQualityCheck()
        if showsSearch { closeSearch() } else { searchFocused = false }
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
        cancelQualityCheck()
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
        cancelQualityCheck()
        GameAlertCenter.shared.dismiss()
        guard let stream = library.resolvedStream(for: game) else { return }
        guard case .play(_, .verified) = library.preferredChannel(for: game) else { tune(stream, for: game); return }
        playback.shutdown()
        playback = MobilePlaybackController()
        let request = UUID()
        qualityRequest = request
        qualityTask = Task { @MainActor in
            let chosen = await library.bestQualityStream(for: game, fallback: stream)
            guard !Task.isCancelled, qualityRequest == request else { return }
            qualityRequest = nil
            qualityTask = nil
            if let chosen { tune(chosen, for: game) }
            else { closePlayer() }
        }
    }

    private func cancelQualityCheck() {
        qualityTask?.cancel()
        qualityTask = nil
        qualityRequest = nil
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
        cancelQualityCheck()
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
        resetGuideScrollPosition()
    }

    private func resetGuideScrollPosition() {
        horizontalOffset = 0
        resetPosition = UUID()
    }

    @ViewBuilder
    private func guide(now: Date) -> some View {
        switch guideViewMode {
        case .tvGuide:
            guideGrid(now: now)
        case .list:
            channelList(now: now)
        }
    }

    private func channelList(now: Date) -> some View {
        MobileGuideChannelScroll(resetToken: resetPosition, protectsTop: true) {
            LazyVStack(spacing: 9) {
                ForEach(channels) { stream in
                    channelListRow(stream, now: now)
                }
            }
            .padding(.horizontal, 12)
            // Separate top clearance from the scrolling content. The UIKit
            // probe resets the real scroll offset when this list's inputs
            // change, so the first favorite always begins below the chrome.
            .padding(.top, MobileGuideLayoutMetrics.listFirstRowTopInset)
            .padding(.bottom, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await library.reload() }
    }

    private func channelListRow(_ stream: XtreamStream, now: Date) -> some View {
        let programs = library.guidePrograms(for: stream)
        let program = programs.first { $0.start <= now && now < $0.end }
        let logoURL = stream.streamIcon.flatMap(URL.init(string:))
        let quality = LiveChannelQuality(name: stream.name).label?
            .split(separator: "·", maxSplits: 1).first.map(String.init)
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

        return Button { selectChannel(stream) } label: {
            HStack(spacing: 0) {
                LineupArtView(url: logoURL, width: 118) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit().padding(9)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.82))
                    }
                }
                .frame(width: 118, height: 80)

                VStack(alignment: .leading, spacing: 4) {
                    Text(stream.name)
                        .font(.inter(12, .semibold))
                        .foregroundStyle(LineupStyle.secondary.opacity(0.82))
                        .lineLimit(1)
                    Text(program?.title ?? "Program guide not available")
                        .font(.inter(15, .heavy))
                        .foregroundStyle(program == nil ? LineupStyle.secondary.opacity(0.46)
                                                        : LineupStyle.text.opacity(0.68))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let program {
                            if program.start <= now && now < program.end {
                                MobileLiveDot()
                                Text("LIVE")
                                    .foregroundStyle(LineupStyle.liveStatus)
                            } else {
                                Text(program.start, format: .dateTime.hour().minute())
                                .foregroundStyle(LineupStyle.secondary.opacity(0.70))
                            }
                        }
                        if let quality {
                            Text(quality.uppercased())
                                .foregroundStyle(LineupStyle.secondary.opacity(0.76))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.22), in: Capsule())
                        }
                    }
                    .font(.inter(9, .heavy))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.trailing, 12)
            }
            .frame(minHeight: 80)
            .background {
                MobileChannelLogoTint(url: logoURL, width: 118, fallback: LineupStyle.raised)
                    .clipShape(shape)
            }
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(shape.strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
        .lineupHoldMenu(stream.name, symbol: "tv", press: .dim, items: { channelMenuItems(stream) }) {
            selectChannel(stream)
        }
        .accessibilityLabel("Watch \(stream.name) live\(program.map { ", \($0.title)" } ?? ", no guide information")\(library.isFavorite(stream) ? ", favorite" : "")")
    }

    private func guideGrid(now: Date) -> some View {
        MobileGuideViewport { viewport, listHeight in
            let logoRailWidth = MobileGuideLayoutMetrics.channelLogoRailWidth(for: viewport.size.width)
            // One horizontal scroller moves every program row and the ruler together.
            // The nested vertical scroller moves logos and programs as a single row.
            // Counter-offset logo tiles keep the channel column frozen horizontally.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    ruler(now: now, logoWidth: logoRailWidth)
                    MobileGuideChannelScroll {
                        LazyVStack(spacing: 0) {
                            ForEach(channels) { stream in
                                ZStack(alignment: .leading) {
                                    // One channel-tinted surface runs behind
                                    // both the artwork panel and its timeline.
                                    MobileChannelLogoTint(
                                        url: stream.streamIcon.flatMap(URL.init(string:)),
                                        width: logoRailWidth,
                                        fallback: LineupStyle.raised)
                                        .frame(width: logoRailWidth + window.width, height: cardHeight)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    HStack(spacing: 0) {
                                        channelTile(stream, logoWidth: logoRailWidth)
                                            .offset(x: horizontalOffset).zIndex(2)
                                        programRow(stream, now: now, viewportWidth: viewport.size.width - logoRailWidth,
                                                   logoWidth: logoRailWidth)
                                    }
                                    .frame(width: logoRailWidth + window.width, height: rowHeight,
                                           alignment: .leading)
                                }
                                .frame(width: logoRailWidth + window.width, height: rowHeight,
                                       alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // Leave a little air below the ruler so the first
                        // favorite never appears tucked under its divider.
                        .padding(.top, MobileGuideLayoutMetrics.gridFirstRowTopInset)
                    }
                    .frame(height: listHeight)
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable { await library.reload() }
                }
                .frame(width: logoRailWidth + window.width, height: viewport.size.height, alignment: .topLeading)
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

    private func ruler(now: Date, logoWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("NOW").font(.inter(8, .bold)).tracking(1)
                Text(now, format: .dateTime.hour().minute())
                    .font(.interDigits(.caption2, .semibold))
            }
                .foregroundStyle(LineupStyle.secondary.opacity(0.74))
                .frame(width: logoWidth, height: 40)
                .background(Color.black)
                .offset(x: horizontalOffset).zIndex(2)
            ZStack(alignment: .topLeading) {
                ForEach(window.ticks, id: \.self) { date in
                    Text(date, format: .dateTime.hour().minute())
                        .font(.interDigits(.caption2, .semibold))
                        .foregroundStyle(LineupStyle.secondary.opacity(0.66))
                        .padding(.leading, 7).frame(width: MobileGuideWindow.pointsPerSecond * 1800, height: 32, alignment: .leading)
                        .offset(x: window.x(date))
                }
            }.frame(width: window.width, height: 40, alignment: .topLeading)
        }
        .background(Color.black)
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
    }

    /// Lineup's verified match, shown only while picking a channel for a game.
    private func isRecommended(_ stream: XtreamStream) -> Bool {
        game != nil && stream.id == recommendedStreamID
    }

    private func channelTile(_ stream: XtreamStream, logoWidth: CGFloat) -> some View {
        let logoURL = stream.streamIcon.flatMap(URL.init(string:))
        return Group {
            ZStack(alignment: .center) {
                LineupArtView(url: logoURL, width: logoWidth) { loaded in
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
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(MobileGuideLayoutMetrics.logoPanelOverlayOpacity))
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        }
        .lineupHoldMenu(stream.name, symbol: "tv", press: .dim, items: { channelMenuItems(stream) }) {
            selectChannel(stream)
        }
        .accessibilityLabel("\(isRecommended(stream) ? "Recommended. " : "")Watch \(stream.name) live\(library.isFavorite(stream) ? ", favorite" : "")")
    }

    private func programRow(_ stream: XtreamStream, now: Date, viewportWidth: CGFloat,
                            logoWidth: CGFloat) -> some View {
        let logoURL = stream.streamIcon.flatMap(URL.init(string:))
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
                        MobileChannelLogoTint(url: logoURL, width: logoWidth, fallback: LineupStyle.raised)
                            .frame(width: width, height: cardHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        if program != nil, live {
                            // Show elapsed time as a translucent wash over the
                            // program tile, not a separate progress bar.
                            let progress = program.map {
                                now.timeIntervalSince($0.start) / $0.end.timeIntervalSince($0.start)
                            } ?? 0
                            Rectangle()
                                .fill(Color.black.opacity(MobileGuideLayoutMetrics.liveProgressOverlayOpacity))
                                .frame(width: MobileGuideLayoutMetrics.liveProgressWidth(cardWidth: width,
                                                                                         progress: progress),
                                       height: cardHeight)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(program?.title ?? "No listing")
                                .font(.inter(.caption, program == nil ? .regular : .semibold)).lineLimit(2)
                                .foregroundStyle(program == nil ? LineupStyle.secondary.opacity(0.52)
                                                               : LineupStyle.text.opacity(0.68))
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
                                .foregroundStyle(live ? LineupStyle.liveStatus : LineupStyle.secondary.opacity(0.68))
                                .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(width: max(1, min(width - textInset, viewportWidth)), alignment: .leading)
                        .offset(x: textInset)
                    }
                    .frame(width: width, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Watch \(stream.name) live. \(program?.title ?? "No guide information")")
                .offset(x: cellX)
            }
        }.frame(width: window.width, height: rowHeight, alignment: .leading)
    }
}

/// Geometry and restrained surface treatments shared by the Guide layouts
/// and their focused tests.
enum MobileGuideLayoutMetrics {
    static let gridFirstRowTopInset: CGFloat = 8
    static let listFirstRowTopInset: CGFloat = 24
    static let liveProgressOverlayOpacity = 0.26
    static let logoPanelOverlayOpacity = 0.035

    /// The channel artwork occupies the same strong left-hand column as the
    /// reference guide, while remaining bounded on narrow and wide devices.
    static func channelLogoRailWidth(for viewportWidth: CGFloat) -> CGFloat {
        min(124, max(108, viewportWidth * 0.32))
    }

    static func liveProgressWidth(cardWidth: CGFloat, progress: Double) -> CGFloat {
        guard cardWidth.isFinite, cardWidth > 0, progress.isFinite else { return 0 }
        return cardWidth * CGFloat(min(1, max(0, progress)))
    }
}

enum MobileGuideSearchPolicy {
    static func shouldCloseAfterSubmission(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct GuideHorizontalPosition: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Favorites order drives the guide's channel order, so this list edits it directly:
/// drag a row to move a channel, swipe or tap the minus to drop it.
private struct FavoritesOrderView: View {
    @Environment(SportsLibrary.self) private var library
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
                LineupToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.buttonStyle(LineupBarButtonStyle(prominent: true)) }
            }
        }
    }
}

/// Keep the ruler and channel list in the Guide's available region.
struct MobileGuideViewport<Content: View>: View {
    private let content: (GeometryProxy, CGFloat) -> Content

    init(@ViewBuilder content: @escaping (GeometryProxy, CGFloat) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { viewport in
            let listHeight = max(0, viewport.size.height - 40)
            content(viewport, listHeight)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
    }
}

/// UIKit can extend this nested scroll view past SwiftUI's proposed height
/// under the native glass bar. Reserve the measured overlap as a content
/// margin on the actual scroller, not by shortening its outer SwiftUI region.
struct MobileGuideChannelScroll<Content: View>: View {
    @State private var topClearance: CGFloat = 0
    @State private var bottomClearance: CGFloat = 0
    @Environment(\.mobileUsesLineupNavigation) private var usesLineupNavigation
    private let resetToken: UUID?
    private let protectsTop: Bool
    private let content: Content

    init(resetToken: UUID? = nil, protectsTop: Bool = false, @ViewBuilder content: () -> Content) {
        self.resetToken = resetToken
        self.protectsTop = protectsTop
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content.background(MobileGuideScrollConfiguration(horizontal: false,
                usesLineupNavigation: usesLineupNavigation, resetToken: resetToken,
                onTopOverlap: protectsTop ? { topClearance = $0 } : nil,
                onBottomOverlap: { bottomClearance = $0 }))
        }
        // A reset token changing must recreate the actual SwiftUI scroll view;
        // setting UIKit's offset alone can lose a race with SwiftUI restoring
        // the prior position during the same update.
        .id(resetToken)
        .contentMargins(.top, protectsTop ? topClearance : 0, for: .scrollContent)
        .contentMargins(.bottom, bottomClearance, for: .scrollContent)
        .contentMargins(.bottom, bottomClearance, for: .scrollIndicators)
        // The measured overlap already includes the home indicator. SwiftUI
        // content margins are added to its safe area, even with UIKit's
        // automatic adjustment disabled. Own only the container's bottom
        // here, preserving top/side protection and keyboard avoidance.
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// Navigation already positions this guide within the safe area. Its two nested
/// scrollers must not add that navigation inset again above the first channel.
struct MobileGuideScrollConfiguration: UIViewRepresentable {
    let horizontal: Bool
    var usesLineupNavigation: Bool? = nil
    var resetToken: UUID? = nil
    var onTopOverlap: ((CGFloat) -> Void)? = nil
    var onBottomOverlap: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.horizontal = horizontal
        probe.resetToken = resetToken
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.horizontal = horizontal
        probe.usesLineupNavigation = usesLineupNavigation
        probe.resetToken = resetToken
        probe.onTopOverlap = onTopOverlap
        probe.onBottomOverlap = onBottomOverlap
        probe.requestRefresh()
    }

    static func dismantleUIView(_ probe: Probe, coordinator: ()) {
        probe.onTopOverlap = nil
        probe.onBottomOverlap = nil
        probe.detachObserver()
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

    /// Physical coverage, independent of scroll offsets and content insets.
    /// The channel list measures its UIScrollView, not an outer hosting view
    /// or the much taller scrolling content.
    static func bottomOverlap(of view: UIView, usesLineupNavigation: Bool? = nil) -> CGFloat {
        guard let window = view.window else { return 0 }
        let viewBottom = view.convert(view.bounds, to: window).maxY
        let customTop = usesLineupNavigation == false ? nil : MobileLineupNavigationBoundary.find(in: window).map {
            $0.convert($0.bounds, to: window).minY
        }
        let barTop = customTop ?? tabBar(in: window).flatMap { bar -> CGFloat? in
            guard !bar.isHidden, bar.alpha > 0.01, bar.window != nil else { return nil }
            return bar.convert(bar.bounds, to: window).minY
        } ?? (window.bounds.maxY - window.safeAreaInsets.bottom)
        return max(0, (viewBottom - barTop).rounded())
    }

    /// Height of a visible navigation bar covering the top of this actual
    /// scroll viewport. SwiftUI's zero scroll-content margin can let the first
    /// row slide beneath a translucent toolbar, so List mode reserves only
    /// the overlap that is physically present.
    static func topOverlap(of view: UIView) -> CGFloat {
        guard let window = view.window else { return 0 }
        let viewport = view.convert(view.bounds, to: window)
        var largestOverlap: CGFloat = 0

        // A SwiftUI NavigationStack may host its UINavigationBar in a private
        // controller that is not in the scroll view's responder chain. Search
        // the visible window hierarchy so List mode measures the same bar that
        // UIKit is actually drawing above the favorites.
        var pendingViews = window.subviews
        while let candidate = pendingViews.popLast() {
            pendingViews.append(contentsOf: candidate.subviews)
            guard let bar = candidate as? UINavigationBar,
                  bar.window === window, !bar.isHidden, bar.alpha > 0.01 else { continue }

            let frame = bar.convert(bar.bounds, to: window)
            guard frame.maxX > viewport.minX, frame.minX < viewport.maxX,
                  frame.maxY > viewport.minY, frame.minY < viewport.maxY else { continue }
            largestOverlap = max(largestOverlap, frame.maxY - viewport.minY)
        }
        return max(0, largestOverlap.rounded())
    }

    final class Probe: UIView {
        var horizontal = false
        var usesLineupNavigation: Bool?
        var resetToken: UUID?
        var onTopOverlap: ((CGFloat) -> Void)?
        var onBottomOverlap: ((CGFloat) -> Void)?
        private(set) var reported: CGFloat?
        private(set) var reportedTop: CGFloat?
        private var scheduled = false
        private weak var observedScroll: UIScrollView?
        private weak var resetScroll: UIScrollView?
        private var appliedResetToken: UUID?
        private weak var boundaryWindow: UIWindow?
        private var observer: ViewportObserver?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detachObserver() }
            else { requestRefresh() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            requestRefresh()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            requestRefresh()
        }

        var enclosingScrollView: UIScrollView? {
            var ancestor = superview
            while let candidate = ancestor {
                if let scroll = candidate as? UIScrollView { return scroll }
                ancestor = candidate.superview
            }
            return nil
        }

        func requestRefresh() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.refresh()
            }
        }

        private func refresh() {
            guard let window, let scroll = enclosingScrollView else { return }
            MobileGuideScrollConfiguration.configure(scroll, horizontal: horizontal)
            if !horizontal, let resetToken,
               (resetScroll !== scroll || appliedResetToken != resetToken) {
                resetScroll = scroll
                appliedResetToken = resetToken
                let top = -scroll.adjustedContentInset.top
                if abs(scroll.contentOffset.y - top) > 0.5 {
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: top), animated: false)
                }
            }
            guard !horizontal, onTopOverlap != nil || onBottomOverlap != nil else { detachObserver(); return }
            if observedScroll !== scroll {
                detachObserver()
                observedScroll = scroll
                let observer = ViewportObserver(frame: scroll.bounds)
                observer.owner = self
                observer.translatesAutoresizingMaskIntoConstraints = false
                observer.isUserInteractionEnabled = false
                observer.isOpaque = false
                observer.accessibilityElementsHidden = true
                scroll.addSubview(observer)
                NSLayoutConstraint.activate([
                    observer.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
                    observer.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
                    observer.topAnchor.constraint(equalTo: scroll.frameLayoutGuide.topAnchor),
                    observer.bottomAnchor.constraint(equalTo: scroll.frameLayoutGuide.bottomAnchor)
                ])
                self.observer = observer
            }
            if boundaryWindow !== window {
                NotificationCenter.default.removeObserver(self, name: MobileLineupNavigationBoundary.geometryDidChange,
                                                          object: boundaryWindow)
                boundaryWindow = window
                NotificationCenter.default.addObserver(self, selector: #selector(boundaryGeometryDidChange(_:)),
                    name: MobileLineupNavigationBoundary.geometryDidChange, object: window)
            }
            if onTopOverlap != nil {
                let top = MobileGuideScrollConfiguration.topOverlap(of: scroll)
                if reportedTop == nil || abs((reportedTop ?? 0) - top) > 0.5 {
                    reportedTop = top
                    onTopOverlap?(top)
                }
            }
            if onBottomOverlap != nil {
                let bottom = MobileGuideScrollConfiguration.bottomOverlap(of: scroll,
                    usesLineupNavigation: usesLineupNavigation)
                if reported == nil || abs((reported ?? 0) - bottom) > 0.5 {
                    reported = bottom
                    onBottomOverlap?(bottom)
                }
            }
        }

        @objc private func boundaryGeometryDidChange(_ notification: Notification) {
            requestRefresh()
        }

        func detachObserver() {
            NotificationCenter.default.removeObserver(self, name: MobileLineupNavigationBoundary.geometryDidChange,
                                                      object: boundaryWindow)
            boundaryWindow = nil
            observer?.owner = nil
            observer?.removeFromSuperview()
            observer = nil
            observedScroll = nil
            resetScroll = nil
            appliedResetToken = nil
            reported = nil
            reportedTop = nil
        }

        /// The content probe may be thousands of points tall and never resize.
        /// This transparent observer follows the actual scroll viewport, so a
        /// native bar's late frame/safe-area change invalidates the measurement.
        private final class ViewportObserver: UIView {
            weak var owner: Probe?
            override func layoutSubviews() { super.layoutSubviews(); owner?.requestRefresh() }
            override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); owner?.requestRefresh() }
            override func didMoveToWindow() { super.didMoveToWindow(); owner?.requestRefresh() }
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
