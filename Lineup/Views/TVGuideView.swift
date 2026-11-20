import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

/// The guide's colours: charcoal, light grey and white, and red for now.
enum GuidePalette {
    static var background: Color { LineupStyle.background }
    /// The channel column and the sidebar, a step darker than the grid so the
    /// names read as a margin rather than as more programmes.
    static var rail: Color { LineupStyle.sidebarRow }
    static var surface: Color { LineupStyle.surface }
    static var raised: Color { LineupStyle.raised }
    static var line: Color { LineupStyle.line }
    static var text: Color { LineupStyle.text }
    static var secondary: Color { LineupStyle.secondary }
    /// The channel artwork tints the grid underneath the programme cards.
    static var rowText: Color { LineupStyle.text.opacity(0.72) }
    static var channelText: Color { LineupStyle.secondary.opacity(0.82) }
}

private enum TVGuideViewMode: String, CaseIterable {
    case tvGuide
    case list

    static let storageKey = "Lineup.tv.guideViewMode.v1"
    static let defaultMode: Self = .tvGuide

    var title: String {
        switch self {
        case .tvGuide: "TV Guide"
        case .list: "List"
        }
    }

    var symbol: String {
        switch self {
        case .tvGuide: "rectangle.grid.1x2"
        case .list: "list.bullet"
        }
    }

    static func restored(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? defaultMode
    }
}

struct GuideView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive = true
    @FocusState private var gridFocus: GuideGridFocus?
    @FocusState private var sidebarFocus: String?
    @State private var returnGridFocus: GuideGridFocus?
    @State private var selectedCategoryID: String?
    @State private var favoritesOnly = true
    /// Recently watched channels in place of every one.
    @State private var recentsOnly = false
    /// The Guide opens on its categories, as the iPhone's does; choosing one
    /// opens its guide, and Back from the top of that comes back here.
    @State private var browsing = true
    /// The row chosen last, for the remote to land on coming back.
    @State private var lastChosen = "favorites"
    /// Coming back from a guide, where the remote already is: the list takes
    /// it, onto the row chosen last. Only then -- the list also appears as
    /// the TV Guide tab is passed over in the tab bar, and taking the remote
    /// there pulled it down out of the bar.
    @State private var refocusCategories = false
    /// A guide just opened from the categories takes the remote once its
    /// channels are in; see `restoreFilteredGuideFocus`.
    @State private var takeGuideFocus = false
    @AppStorage(TVGuideViewMode.storageKey) private var guideViewModeValue = TVGuideViewMode.defaultMode.rawValue
    /// Categories taken out of the Guide, as the iPhone keeps them: by
    /// provider, so Set Up with iPhone brings the phone's own across.
    @AppStorage(MobileGuideCategoryVisibility.storageKey) private var hiddenCategoriesRaw = "{}"
    @State private var hiddenMemo = TVGuideHiddenCategories()
    @State private var searchActive = false
    @State private var query = ""
    /// What is full screen, with the preview's player when it carries on;
    /// see the Live tab's.
    @State private var fullScreen: TVFullScreenItem?
    @State private var multiviewPrimary: XtreamStream?
    @State private var multiviewSession: MultiviewSession?
    @State private var guideNow = Date()
    /// What the remote is on, held outside this screen's own state: see
    /// `GuideFocusModel`.
    @State private var focus = GuideFocusModel()
    /// A channel whose past programmes are being chosen from.
    @State private var catchUpChannel: XtreamStream?
    @State private var sidebarVisible = false
    @State private var closeSidebarWhenReady = false
    /// Asks the grid to go back to its first row; see `backAction`.
    @State private var topRequest = 0
    @State private var reorderingFavorites = false
    /// Where the remote is taking focus, and which rows exist to take it.
    @State private var navigation = GuideNavigation()
    @State private var programWindow = TVGuideProgramWindow()
    @State private var channelSnapshot = TVGuideChannelSnapshot.empty
    @State private var installedChannels: ChannelRequest?
    @State private var initialPreview: TVGuideChannelSnapshot.Preview?
    private struct ChannelRequest: Hashable {
        let library: ObjectIdentifier
        let revision: Int
        let active: Bool
        let query: GuideChannelList.Query
    }
    /// This provider's hidden categories. Their channels stay out of All
    /// Channels and the Guide's search; Favorites and Recently Watched keep
    /// theirs.
    private var hiddenCategoryIDs: Set<String> {
        hiddenMemo.ids(raw: hiddenCategoriesRaw, provider: library.activeProfile?.id)
    }
    private func setCategory(_ id: String, hidden: Bool) {
        if let raw = MobileGuideCategoryVisibility(hiddenCategoriesRaw)
            .setting(hidden, category: id, provider: library.activeProfile?.id) {
            hiddenCategoriesRaw = raw
        }
    }
    private func showAllCategories() {
        var raw = hiddenCategoriesRaw
        for id in hiddenCategoryIDs {
            raw = MobileGuideCategoryVisibility(raw).setting(false, category: id, provider: library.activeProfile?.id) ?? raw
        }
        hiddenCategoriesRaw = raw
    }
    private var channelRequest: ChannelRequest {
        ChannelRequest(library: ObjectIdentifier(library), revision: library.streamsRevision,
            active: isActive && (!browsing || takeGuideFocus) && scenePhase == .active && fullScreen == nil && multiviewSession == nil,
            query: .init(categoryID: searchActive ? nil : selectedCategoryID,
                favoritesOnly: !searchActive && favoritesOnly,
                recentsOnly: !searchActive && showsRecents, text: query,
                favorites: !searchActive && favoritesOnly ? library.favoriteStreamOrder : [],
                recents: !searchActive && showsRecents ? library.recentStreamOrder : [],
                hiddenCategories: hiddenCategoryIDs))
    }
    /// Recently watched channels are what's listed: not while a category or
    /// favorites are chosen.
    private var showsRecents: Bool { recentsOnly && !favoritesOnly && selectedCategoryID == nil }
    private var presentedChannels: ChannelRequest? {
        let request = channelRequest
        guard let installedChannels, installedChannels.library == request.library,
              installedChannels.revision == request.revision,
              installedChannels.query == request.query || sidebarVisible else { return nil }
        return installedChannels
    }
    private var filtered: [XtreamStream] {
        presentedChannels == nil ? [] : channelSnapshot.streams
    }
    private var loadingChannels: Bool {
        channelRequest.active && (installedChannels != channelRequest || library.isInitialProviderSync)
    }
    private var switchingSidebarCategory: Bool {
        sidebarVisible && presentedChannels != nil && installedChannels?.query != channelRequest.query
    }
    private func channelPosition(_ id: Int?) -> Int? {
        guard let id, !filtered.isEmpty else { return nil }
        return channelSnapshot.positions[id]
    }
    private func loadChannels() async {
        let request = channelRequest
        guard request.active else { return }
        if installedChannels == request {
            openSelectedGuide()
            return
        }
        let switchesCategory = browsing || (sidebarVisible && installedChannels?.query != request.query)
        let streams = library.streams
        guard let snapshot = try? await TVGuideChannelSnapshot.load(streams, query: request.query),
              !Task.isCancelled, channelRequest == request else { return }
        if switchesCategory {
            // Make the first preview available with the rows so the grid does
            // not jump down a second time when its preview arrives.
            let now = Date()
            let preview = try? await TVGuideChannelSnapshot.preview(in: snapshot.streams,
                                                                    programs: library.programsByChannel, now: now)
            guard !Task.isCancelled, channelRequest == request else { return }
            initialPreview = preview
            guideNow = now
            focus.item = nil
            navigation.clearTarget()
        } else {
            initialPreview = nil
        }
        channelSnapshot = snapshot
        installedChannels = request
        if browsing {
            openSelectedGuide()
            return
        }
        if sidebarVisible {
            if closeSidebarWhenReady { closeSidebar() }
            return
        }
        // The remote may be where it was in a list that has changed under it.
        focus.setBelowTop((channelPosition(gridFocus?.streamID) ?? 0) > 0)
        restoreFilteredGuideFocus()
    }

    private func openSelectedGuide() {
        guard browsing, takeGuideFocus else { return }
        browsing = false
    }
    /// The remote has landed on a programme, or on a channel in List.
    private func remoteLanded(on stream: XtreamStream, item: GuideFocusItem?) {
        if focus.item != item { focus.item = item }
        focus.setBelowTop((channelPosition(stream.id) ?? 0) > 0)
    }
    private var selectedTitle: String {
        let selection = presentedChannels?.query ?? channelRequest.query
        if selection.favoritesOnly { return "Favorites" }
        if selection.recentsOnly { return "Recently Watched" }
        return library.categories.first { $0.id == selection.categoryID }?.categoryName ?? "All channels"
    }
    private var guideViewMode: TVGuideViewMode { TVGuideViewMode.restored(guideViewModeValue) }

    private var controlBar: GuideControlBar {
        GuideControlBar(
            title: selectedTitle,
            channelCount: filtered.count,
            searchActive: $searchActive,
            query: $query,
            multiviewTitle: multiviewPrimary?.name,
            now: guideNow,
            guideViewModeValue: $guideViewModeValue,
            onBrowse: browseCategories,
            onCancelMultiview: { multiviewPrimary = nil }
        )
    }

    var body: some View {
        GeometryReader { container in
            let layout = GuideLayout(width: container.size.width - 2 * GuideLayout.margin)
            NavigationStack {
                ZStack {
                if browsing {
                    categoryList.transition(.opacity)
                } else {
                VStack(alignment: .leading, spacing: 18) {
                    GuideHeader(focus: focus, controls: controlBar, streams: filtered,
                                positions: channelSnapshot.positions,
                                installed: presentedChannels.map { AnyHashable($0) }, initialPreview: initialPreview,
                                active: channelRequest.active, now: guideNow)

                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            if guideViewMode == .tvGuide {
                                GuideTimelineHeader(now: guideNow)
                            } else {
                                GuideListHeader(now: guideNow, channelWidth: layout.listChannelWidth)
                            }
                            if filtered.isEmpty {
                                if loadingChannels {
                                    ProgressView("Loading channels…")
                                        .padding(.top, 28).padding(.leading, 14)
                                } else {
                                    Label(favoritesOnly ? "Your favorite channels will appear here."
                                            : showsRecents ? "Channels you watch will appear here."
                                            : "No channels in this category.",
                                          systemImage: favoritesOnly ? "star" : showsRecents ? "clock.arrow.circlepath" : "rectangle.stack")
                                        .font(.inter(22, .medium)).foregroundStyle(GuidePalette.secondary)
                                        .padding(.top, 28).padding(.leading, 14)
                                        .focusable()
                                        .focused($gridFocus, equals: GuideGridFocus(streamID: -1, programStart: nil))
                                        .modifier(GuideLeftBoundary(enabled: !sidebarVisible && !searchActive, onOpen: openSidebar))
                                }
                            } else {
                                ScrollViewReader { proxy in
                                // Kept for the rows: a row that is not drawn
                                // again keeps the actions it was first given,
                                // and those find the list through here.
                                let _ = (navigation.scroll = proxy)
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(filtered) { stream in
                                            let programs = visibleGuidePrograms(for: stream)
                                            let currentProgram = programs.first { $0.start <= guideNow && guideNow < $0.end }
                                            Group {
                                                if guideViewMode == .tvGuide {
                                                    GuideChannelRow(
                                                        stream: stream,
                                                        visiblePrograms: programs,
                                                        favoritesMode: presentedChannels?.query.favoritesOnly == true,
                                                        now: guideNow,
                                                        gridFocus: $gridFocus,
                                                        focus: focus,
                                                        multiviewPrimaryID: multiviewPrimary?.id,
                                                        onPlay: { select(stream) },
                                                        onStartMultiview: { multiviewPrimary = stream },
                                                        onReorderFavorites: { reorderingFavorites = true },
                                                        onStartOver: { watchRecording(of: stream, programme: nil) },
                                                        onCatchUp: { catchUpChannel = stream },
                                                        onMoveFocus: { direction, focus in
                                                            moveGuideFocus(direction, from: focus, proxy: navigation.scroll ?? proxy)
                                                        },
                                                        onFocusProgram: { program in
                                                            remoteLanded(on: stream, item: GuideFocusItem(stream: stream, program: program))
                                                        }
                                                    )
                                                    // Drawn again when its channel, its
                                                    // programmes or the time change, not
                                                    // each time the remote moves.
                                                    .equatable()
                                                } else {
                                                    GuideChannelListRow(
                                                        stream: stream,
                                                        program: currentProgram,
                                                        now: guideNow,
                                                        quality: guideQuality(stream),
                                                        favoritesMode: presentedChannels?.query.favoritesOnly == true,
                                                        gridFocus: $gridFocus,
                                                        focus: focus,
                                                        multiviewPrimaryID: multiviewPrimary?.id,
                                                        onPlay: { select(stream) },
                                                        onStartMultiview: { multiviewPrimary = stream },
                                                        onReorderFavorites: { reorderingFavorites = true },
                                                        onStartOver: { watchRecording(of: stream, programme: nil) },
                                                        onCatchUp: { catchUpChannel = stream },
                                                        onMoveFocus: { direction, focus in
                                                            moveGuideListFocus(direction, from: focus, proxy: navigation.scroll ?? proxy)
                                                        },
                                                        onFocus: {
                                                            remoteLanded(on: stream, item: currentProgram.map { GuideFocusItem(stream: stream, program: $0) })
                                                        }
                                                    )
                                                    .equatable()
                                                }
                                            }
                                            .id(stream.id)
                                            .onAppear { rowBuilt(stream.id) }
                                            .onDisappear { navigation.builtRows.remove(stream.id) }
                                        }
                                    }.padding(.top, 2)
                                }
                                .onChange(of: topRequest) { _, _ in
                                    guard let first = filtered.first else { return }
                                    let target = firstRowFocus(first)
                                    navigation.heading(to: target, row: 0,
                                                       from: channelPosition(gridFocus?.streamID) ?? 0)
                                    proxy.scrollTo(first.id, anchor: .top)
                                    if navigation.builtRows.contains(first.id) { gridFocus = target }
                                }
                                .onChange(of: sidebarVisible) { _, visible in
                                    guard !visible, let target = gridFocus else { return }
                                    proxy.scrollTo(target.streamID, anchor: returnGridFocus == nil ? .top : .center)
                                    Task { @MainActor in
                                        await Task.yield()
                                        guard !sidebarVisible else { return }
                                        gridFocus = target
                                    }
                                }
                                .onChange(of: installedChannels) { _, _ in
                                    guard sidebarVisible, returnGridFocus == nil, let first = filtered.first else { return }
                                    proxy.scrollTo(first.id, anchor: .top)
                                }
                                }
                            }
                        }
                        .disabled(sidebarVisible && !searchActive)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { grid in
                            grid.opacity(switchingSidebarCategory ? 0.8 : 1)
                        }
                        .overlay(alignment: .topLeading) {
                            if guideViewMode == .tvGuide {
                                GuideEPGLeadingFade(
                                    startX: GuideLayout.inset + layout.channelWidth,
                                    width: min(248, max(168, layout.slotWidth * 0.92))
                                )
                            }
                        }

                        if sidebarVisible && !searchActive {
                            GuideSidebar(
                                hidden: hiddenCategoryIDs,
                                selectedCategoryID: selectedCategoryID,
                                favoritesOnly: favoritesOnly,
                                recentsOnly: recentsOnly,
                                focus: $sidebarFocus,
                                onCollapse: closeSidebar,
                                choose: chooseSidebarCategory
                            )
                            .frame(width: layout.channelWidth)
                            .frame(maxHeight: .infinity)
                            .background(GuidePalette.rail)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(GuidePalette.line).frame(width: 1)
                            }
                            .lineupShadow(.overlayFromEdge)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .focusSection()
                        }
                    }
                    // The grid sits straight on the ground, clipped square so
                    // rows leave cleanly under the time bar rather than
                    // drawing past it.
                    .clipShape(Rectangle())
                }
                .padding(.horizontal, GuideLayout.margin).padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
                .task {
                    await Task.yield()
                    guard !Task.isCancelled, !browsing, takeGuideFocus else { return }
                    restoreFilteredGuideFocus()
                }
                }
                }
                .tvBackToTabs()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: browsing)
                .ignoresSafeArea(.container, edges: .bottom)
                .background(GuidePalette.background.ignoresSafeArea())
                .lineupFullScreenCover(item: $fullScreen) { item in
                    PlayerView(
                        urls: library.playbackURLs(for: item.stream),
                        title: item.stream.name,
                        program: library.guidePrograms(for: item.stream).normalizedEPG().first { $0.isLive },
                        channelID: item.stream.id,
                        channel: item.stream,
                        // Up and Down go through the Guide's own list, as
                        // it stands: the category or favourites on screen.
                        lineup: filtered,
                        recording: item.recording,
                        startsOver: item.startsOver,
                        continuing: item.preview
                    )
                }
                .lineupFullScreenCover(item: $catchUpChannel) { stream in
                    TVCatchUpScreen(stream: stream) { programme in
                        catchUpChannel = nil
                        watchRecording(of: stream, programme: programme)
                    }
                }
                .lineupFullScreenCover(item: $multiviewSession) { session in
                    MultiviewView(
                        primary: session.primary,
                        secondary: session.secondary,
                        primaryURLs: library.playbackURLs(for: session.primary),
                        secondaryURLs: library.playbackURLs(for: session.secondary),
                        primaryGame: session.primaryGame,
                        secondaryGame: session.secondaryGame
                    )
                }
                .lineupFullScreenCover(isPresented: $reorderingFavorites) {
                    TVFavoritesOrderView()
                }
                .task(id: channelRequest.active && !browsing) {
                    guard channelRequest.active, !browsing else { return }
                    if Date().timeIntervalSince(guideNow) >= 30 { guideNow = Date() }
                    while !Task.isCancelled {
                        // The now line and progress bars move a pixel or two a
                        // minute: twice a minute is plenty, and every redraw of
                        // the Guide is every visible row drawn again.
                        do { try await Task.sleep(for: .seconds(30)) }
                        catch { return }
                        guideNow = Date()
                    }
                }
                .task(id: channelRequest) { await loadChannels() }
                .onChange(of: guideViewModeValue) { _, value in restoreGuideFocus(for: value) }
                .onChange(of: library.guideRevision) { _, _ in
                    guard channelRequest.active, guideViewMode == .tvGuide, !sidebarVisible,
                          let current = gridFocus, let row = channelPosition(current.streamID),
                          filtered.indices.contains(row) else { return }
                    let stream = filtered[row]
                    let programs = visibleGuidePrograms(for: stream)
                    let hasCurrentCell = current.programStart.map { start in
                        programs.contains { $0.start == start }
                    } ?? programs.isEmpty
                    if !hasCurrentCell {
                        gridFocus = firstRowFocus(stream)
                    }
                }
                // The one place the remote's position is read from the focus
                // engine. The cells take it from the model, each on its own.
                .onChange(of: gridFocus) { _, place in
                    if focus.current != place { focus.current = place }
                    if let row = channelPosition(place?.streamID) { navigation.landed(on: row) }
                }
                .modifier(GuideBackAction(focus: focus, action: backAction))
            }
            .environment(\.guideLayout, layout)
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private func openSidebar() {
        guard !sidebarVisible, !searchActive else { return }
        returnGridFocus = gridFocus
        gridFocus = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sidebarVisible = true }
    }

    private func closeSidebar() {
        if channelRequest.active, installedChannels != channelRequest {
            closeSidebarWhenReady = true
            return
        }
        closeSidebarWhenReady = false
        sidebarFocus = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sidebarVisible = false }
        let channels = filtered
        let previous = channelPosition(returnGridFocus?.streamID).map { channels[$0] }
        let stream = previous ?? channels.first
        guard let stream else {
            gridFocus = GuideGridFocus(streamID: -1, programStart: nil)
            return
        }
        if previous != nil, guideViewMode == .tvGuide {
            let programs = visibleGuidePrograms(for: stream)
            let restored = programs.first { $0.start == returnGridFocus?.programStart } ?? programs.first
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: restored?.start)
        } else {
            gridFocus = firstRowFocus(stream)
        }
    }

    private func restoreGuideFocus(for rawValue: String) {
        let channels = filtered
        guard let stream = channelPosition(gridFocus?.streamID).map({ channels[$0] }) ?? channels.first else { return }
        guard TVGuideViewMode.restored(rawValue) == .tvGuide else {
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: nil)
            return
        }
        let programs = visibleGuidePrograms(for: stream)
        let current = programs.first { $0.start <= guideNow && guideNow < $0.end } ?? programs.first
        gridFocus = GuideGridFocus(streamID: stream.id, programStart: current?.start)
    }

    /// What Back does in the Guide: close the categories; from anywhere
    /// below the first channel, go back to the top. Otherwise nothing here
    /// takes it, and the system moves up to the tab bar -- so a long way
    /// down the Guide, Back twice reaches the tabs, where it used to take
    /// holding Up all the way.
    private func backAction(belowTop: Bool) -> (() -> Void)? {
        if browsing { return nil }
        if sidebarVisible && !searchActive { return { closeSidebar() } }
        if belowTop { return { topRequest &+= 1 } }
        if searchActive { return nil }
        return { browseCategories() }
    }

    /// Back to the categories, from the top of a guide.
    private func browseCategories() {
        gridFocus = nil
        focus.setBelowTop(false)
        navigation.clearTarget()
        refocusCategories = true
        browsing = true
    }

    private func selectCategory(_ choice: TVGuideCategoryChoice) {
        favoritesOnly = choice == .favorites
        recentsOnly = choice == .recents
        if case .category(let id) = choice { selectedCategoryID = id } else { selectedCategoryID = nil }
    }

    private func chooseSidebarCategory(_ choice: TVGuideCategoryChoice) {
        let previous = channelRequest.query
        closeSidebarWhenReady = false
        selectCategory(choice)
        if previous != channelRequest.query { returnGridFocus = nil }
    }

    private var categoryList: some View {
        let hidden = hiddenCategoryIDs
        return TVGuideCategoryList(
            categories: library.categories.filter { !hidden.contains($0.id) },
            hiddenCategories: library.categories.filter { hidden.contains($0.id) },
            onHide: { setCategory($0.id, hidden: true) },
            onShow: { setCategory($0.id, hidden: false) },
            onShowAll: showAllCategories,
            hasFavorites: !library.favoriteStreamOrder.isEmpty,
            hasRecents: !library.recentStreamOrder.isEmpty,
            channelCount: library.streams.count,
            lastChosen: lastChosen,
            takesFocus: refocusCategories,
            onTookFocus: { refocusCategories = false }
        ) { choice in
            lastChosen = choice.id
            refocusCategories = false
            selectCategory(choice)
            searchActive = false
            query = ""
            takeGuideFocus = true
            if installedChannels == channelRequest {
                guideNow = Date()
                openSelectedGuide()
            }
        }
    }

    /// The first channel's cell: what is on now in the Guide, the row itself
    /// in List.
    private func firstRowFocus(_ stream: XtreamStream) -> GuideGridFocus {
        guard guideViewMode == .tvGuide else { return GuideGridFocus(streamID: stream.id, programStart: nil) }
        let programs = visibleGuidePrograms(for: stream)
        let program = programs.first { $0.start <= guideNow && guideNow < $0.end } ?? programs.first
        return GuideGridFocus(streamID: stream.id, programStart: program?.start)
    }

    private func restoreFilteredGuideFocus() {
        // Only where the remote already is: a guide just opened from the
        // categories, or the grid itself. Channels load as the tab is passed
        // over in the tab bar too, and taking the remote then pulled it down
        // out of the bar.
        let opening = takeGuideFocus
        guard opening || gridFocus != nil else { return }
        if opening, loadingChannels, filtered.isEmpty { return }
        takeGuideFocus = false
        guard opening || channelPosition(gridFocus?.streamID) == nil else { return }
        guard let first = filtered.first else {
            gridFocus = GuideGridFocus(streamID: -1, programStart: nil)
            return
        }
        let target = firstRowFocus(first)
        navigation.heading(to: target, row: 0, from: 0)
        gridFocus = target
    }

    /// Keep vertical remote movement on what is airing now.
    ///
    /// Program blocks have different widths from channel to channel. Native
    /// geometric focus therefore sometimes treats a future block as the
    /// nearest target when moving up or down. Vertical movement is channel
    /// browsing, so it always lands on the adjacent channel's on-air block.
    /// Horizontal movement remains schedule browsing and walks every visible
    /// listing in the current row.
    ///
    /// A press is taken from where the last one was going, while that one is
    /// still on its way. Presses come faster than focus settles when a
    /// direction is held or swiped, and one taken from the cell that
    /// happened to have focus -- a row or more behind -- sent focus back up
    /// the guide it had just come down. A row not yet built is scrolled in
    /// first and focused once it is there; asked for before, focus had
    /// nowhere to go and fell back to a row on screen.
    private func moveGuideFocus(_ direction: MoveCommandDirection, from cell: GuideGridFocus,
                                proxy: ScrollViewProxy) {
        let source = navigation.headingTo() ?? cell
        guard let row = channelPosition(source.streamID) else { return }

        switch direction {
        case .up, .down:
            let targetRow = direction == .up ? row - 1 : row + 1
            guard filtered.indices.contains(targetRow) else { return }
            let stream = filtered[targetRow]
            let programs = visibleGuidePrograms(for: stream)
            let onAir = programs.first { $0.start <= guideNow && guideNow < $0.end }
            send(GuideGridFocus(streamID: stream.id, programStart: (onAir ?? programs.first)?.start), proxy: proxy)

        case .left, .right:
            let stream = filtered[row]
            let programs = visibleGuidePrograms(for: stream)
            guard !programs.isEmpty else {
                if direction == .left { openSidebar() }
                return
            }
            let current = source.programStart.flatMap { start in
                programs.firstIndex(where: { $0.start == start })
            } ?? 0
            let target = direction == .left ? current - 1 : current + 1
            guard programs.indices.contains(target) else {
                if direction == .left { openSidebar() }
                return
            }
            send(GuideGridFocus(streamID: stream.id, programStart: programs[target].start), proxy: proxy)

        default:
            return
        }
    }

    /// In List mode the remote moves between channels only. Horizontal
    /// movement opens the existing category/favorites sidebar, just as it
    /// does at the left edge of the TV Guide grid.
    private func moveGuideListFocus(_ direction: MoveCommandDirection, from cell: GuideGridFocus,
                                    proxy: ScrollViewProxy) {
        let source = navigation.headingTo() ?? cell
        guard let row = channelPosition(source.streamID) else { return }
        switch direction {
        case .left:
            openSidebar()
        case .up, .down:
            let targetRow = direction == .up ? row - 1 : row + 1
            guard filtered.indices.contains(targetRow) else { return }
            send(GuideGridFocus(streamID: filtered[targetRow].id, programStart: nil), proxy: proxy)
        default:
            break
        }
    }

    private func send(_ target: GuideGridFocus, proxy: ScrollViewProxy) {
        guard let row = channelPosition(target.streamID) else { return }
        navigation.heading(to: target, row: row, from: channelPosition(gridFocus?.streamID) ?? row)
        if navigation.builtRows.contains(target.streamID) {
            gridFocus = target
        } else {
            // Focused as it is built; see `rowBuilt`.
            proxy.scrollTo(target.streamID)
        }
    }

    /// A row has been built. If focus was on its way to it, it goes there now.
    private func rowBuilt(_ streamID: Int) {
        navigation.builtRows.insert(streamID)
        if let row = channelPosition(gridFocus?.streamID) { navigation.landed(on: row) }
        guard let target = navigation.headingTo(), target.streamID == streamID,
              !sidebarVisible, gridFocus != target else { return }
        gridFocus = target
    }

    private func visibleGuidePrograms(for stream: XtreamStream) -> [CurrentProgram] {
        let start = guideTimelineAnchor(guideNow)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        guard let channel = stream.epgChannelID else { return [] }
        return programWindow.programs(channel: channel, library: ObjectIdentifier(library), revision: library.guideRevision,
                                      start: start, end: end) { library.guidePrograms(for: stream) }
    }

    /// A channel's recording full screen: a programme from the past, or with
    /// none, the programme on now from its start. The preview's stream is
    /// let go first -- two streams of one channel is two connections.
    private func watchRecording(of stream: XtreamStream, programme: CatchUpProgramme?) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            fullScreen = TVFullScreenItem(stream: stream, recording: programme, startsOver: programme == nil)
        }
    }

    /// Select on a channel plays it full screen, as tapping one does on the
    /// phone. Choosing a second channel for multiview opens both.
    private func select(_ stream: XtreamStream) {
        guard let primary = multiviewPrimary else {
            fullScreen = TVFullScreenItem(stream: stream)
            return
        }
        guard primary.id != stream.id else { return }
        multiviewPrimary = nil
        multiviewSession = MultiviewSession(primary: primary, secondary: stream,
                                           primaryGame: nil, secondaryGame: nil)
    }
}

private struct GuideFocusItem: Equatable {
    let stream: XtreamStream
    let program: CurrentProgram
}

/// What the remote is on in the grid.
///
/// It was state of the Guide itself, read in the Guide's own body, so every
/// press of the remote drew the whole screen again: each row on it handed a
/// fresh set of actions and laid out afresh, cell by cell, to change one
/// border and the panel above. It is kept here now and read by the two
/// things that show it -- the panel, and what Back does -- and a press
/// redraws those and the two cells the remote moved between.
@Observable private final class GuideFocusModel {
    /// The cell the remote is on. Every cell reads this to know whether it
    /// is the one: a cell handed the focus binding alone is not told when
    /// it changes, and went on drawing itself unfocused.
    var current: GuideGridFocus?
    /// The programme under the remote, for the panel above the grid.
    var item: GuideFocusItem?
    /// Whether the remote is below the first channel, where Back goes to
    /// the top rather than out to the categories.
    private(set) var belowTop = false

    func setBelowTop(_ value: Bool) {
        if belowTop != value { belowTop = value }
    }
}

/// Back in the Guide. Only this reads where the remote is.
private struct GuideBackAction: ViewModifier {
    let focus: GuideFocusModel
    let action: (Bool) -> (() -> Void)?

    func body(content: Content) -> some View {
        content.onExitCommand(perform: action(focus.belowTop))
    }
}

/// The head of the Guide: the programme under the remote with the controls
/// beside it, or the controls alone before there is one.
private struct GuideHeader: View {
    @Environment(SportsLibrary.self) private var library
    let focus: GuideFocusModel
    let controls: GuideControlBar
    /// The channels listed, and each one's place among them.
    let streams: [XtreamStream]
    let positions: [Int: Int]
    /// The list those came from, so the first programme is looked for again
    /// when it changes.
    let installed: AnyHashable?
    let initialPreview: TVGuideChannelSnapshot.Preview?
    let active: Bool
    let now: Date
    /// What is on the first channel with a guide, shown until the remote
    /// lands on something.
    @State private var defaultPreview: (channels: AnyHashable?, item: TVGuideChannelSnapshot.Preview?)?

    private func listed(_ id: Int?) -> Bool {
        guard let id, !streams.isEmpty else { return false }
        return positions[id] != nil
    }

    private struct PreviewRequest: Hashable {
        let channels: AnyHashable?
        let guideRevision: Int
        let now: Date
        let active: Bool
    }

    private var previewRequest: PreviewRequest {
        PreviewRequest(channels: installed, guideRevision: library.guideRevision, now: now,
                       active: active && !listed(focus.item?.stream.id))
    }

    private var previewItem: GuideFocusItem? {
        if let item = focus.item, listed(item.stream.id) { return item }
        let preview = defaultPreview.flatMap { $0.channels == installed ? $0 : nil }
        if let preview = (preview == nil ? initialPreview : preview?.item), listed(preview.stream.id) {
            return GuideFocusItem(stream: preview.stream, program: preview.program)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let previewItem {
                GuidePreviewPanel(
                    controls: controls,
                    item: previewItem,
                    categoryName: library.categories.first(where: { $0.id == previewItem.stream.categoryID })?.categoryName ?? "Live TV",
                    quality: guideQuality(previewItem.stream),
                    now: now
                )
                .frame(height: GuidePreviewPanel.height)
                // The video reaches the screen's left edge; the info
                // pane keeps the Guide's readable inset on the right.
                .padding(.leading, -GuideLayout.margin)
                .padding(.trailing, GuideLayout.inset)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                controls.padding(.horizontal, GuideLayout.inset)
            }
        }
        .task(id: previewRequest) { await loadDefaultPreview() }
    }

    private func loadDefaultPreview() async {
        let request = previewRequest
        guard request.active else { return }
        let programs = library.programsByChannel
        let preview = try? await TVGuideChannelSnapshot.preview(in: streams, programs: programs, now: now)
        guard !Task.isCancelled, previewRequest == request else { return }
        defaultPreview = (request.channels, preview)
    }
}

private struct GuideControlBar: View {
    let title: String
    let channelCount: Int
    @Binding var searchActive: Bool
    @Binding var query: String
    let multiviewTitle: String?
    let now: Date
    @Binding var guideViewModeValue: String
    let onBrowse: () -> Void
    let onCancelMultiview: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            if let multiviewTitle {
                GuideTitleBlock(eyebrow: "MULTIVIEW  ·  CHOOSE A SECOND CHANNEL", title: multiviewTitle)
            } else if searchActive {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(GuidePalette.secondary)
                    TextField("Search channels", text: $query)
                        .textFieldStyle(.plain).focusEffectDisabled()
                        .font(.inter(22, .medium))
                }
                .padding(.horizontal, 18).frame(maxWidth: 620, minHeight: 52)
                .background(GuidePalette.surface, in: Capsule())
            } else {
                GuideTitleBlock(eyebrow: "TV GUIDE", title: title)
            }
            if !searchActive && multiviewTitle == nil {
                GuideHeaderButton(title: "Categories", symbol: "list.bullet", action: onBrowse)
            }
            Spacer(minLength: 12)
            Text("\(channelCount) CHANNELS")
                .font(.inter(13, .heavy)).tracking(0.6)
                .foregroundStyle(GuidePalette.secondary)
            Rectangle().fill(GuidePalette.line).frame(width: 1, height: 26)
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.interDigits(24, .semibold))
                .foregroundStyle(GuidePalette.text)
                .fixedSize()
                .accessibilityLabel("Current time, \(now.formatted(date: .omitted, time: .shortened))")
            GuideHeaderButton(title: searchActive ? "Close" : "Search", symbol: searchActive ? "xmark" : "magnifyingglass") {
                searchActive.toggle()
                if !searchActive { query = "" }
            }
            if !searchActive && multiviewTitle == nil {
                TVGuideViewModePicker(value: $guideViewModeValue)
            }
            if multiviewTitle != nil { GuideHeaderButton(title: "Cancel", symbol: "xmark", action: onCancelMultiview) }
        }
        .foregroundStyle(GuidePalette.text)
        .frame(height: 64)
    }
}

/// This provider's hidden categories as last read, so the saved choice is
/// decoded when it changes rather than each time the Guide asks, which is
/// several times in one redraw. A class, and so not observed.
private final class TVGuideHiddenCategories {
    private var raw = ""
    private var provider: UUID?
    private var held: Set<String> = []

    func ids(raw: String, provider: UUID?) -> Set<String> {
        if raw != self.raw || provider != self.provider {
            self.raw = raw
            self.provider = provider
            held = MobileGuideCategoryVisibility(raw).hiddenIDs(provider: provider)
        }
        return held
    }
}

/// What the Guide's first page offers.
enum TVGuideCategoryChoice: Equatable {
    case favorites, recents, all
    case category(String)

    var id: String {
        switch self {
        case .favorites: "favorites"
        case .recents: "recents"
        case .all: "all"
        case .category(let id): "category-" + id
        }
    }
}

/// The TV Guide's first page, as the iPhone's: Favorites, what was watched
/// lately and every channel, then the provider's categories in its order.
/// Choosing one opens its guide. This replaced a menu over the guide, which
/// hid the categories behind a button and a long list of them in a sheet.
private struct TVGuideCategoryList: View {
    let categories: [XtreamCategory]
    /// Categories the viewer took out, to be put back from the foot of the
    /// list.
    let hiddenCategories: [XtreamCategory]
    let onHide: (XtreamCategory) -> Void
    let onShow: (XtreamCategory) -> Void
    let onShowAll: () -> Void
    @State private var showingHidden = false
    let hasFavorites: Bool
    let hasRecents: Bool
    let channelCount: Int
    /// The row chosen last, where the remote lands coming back.
    let lastChosen: String
    /// Whether the list takes the remote as it appears: coming back from a
    /// guide, never as the tab is passed over in the tab bar.
    let takesFocus: Bool
    let onTookFocus: () -> Void
    let choose: (TVGuideCategoryChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TV GUIDE")
                    .font(.inter(15, .heavy)).tracking(LineupPanelStyle.headerTracking)
                    .foregroundStyle(LineupPanelStyle.caption)
                Text("Categories")
                    .font(.inter(46, .heavy))
                    .foregroundStyle(GuidePalette.text)
                Text(channelCount == 1 ? "1 channel" : "\(channelCount) channels")
                    .font(.inter(20, .medium))
                    .foregroundStyle(GuidePalette.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        row(.favorites, "Favorites", symbol: "star.fill", detail: hasFavorites ? nil : "None yet")
                        if hasRecents { row(.recents, "Recently Watched", symbol: "clock.arrow.circlepath") }
                        row(.all, "All Channels", symbol: "tv")
                        if !categories.isEmpty {
                            Text("CATEGORIES")
                                .font(.inter(15, .heavy)).tracking(1.2)
                                .foregroundStyle(GuidePalette.secondary)
                                .padding(.top, 22).padding(.bottom, 4).padding(.leading, 6)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(categories) { category in
                            row(.category(category.id), category.categoryName, symbol: "folder.fill")
                                // Hold Select on a category to take it out of
                                // the Guide, as on iPhone.
                                .tvHoldMenu(category.categoryName, symbol: "folder") {
                                    [TVChoice("Hide Category", symbol: "eye.slash") { onHide(category) }]
                                }
                        }
                        if !hiddenCategories.isEmpty { hiddenRow }
                    }
                    .padding(.vertical, 20).padding(.horizontal, 30)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .task(id: takesFocus) {
                    guard takesFocus else { return }
                    proxy.scrollTo(lastChosen, anchor: .center)
                    do { try await Task.sleep(for: .milliseconds(250)) }
                    catch { return }
                    onTookFocus()
                }
            }
        }
        .frame(width: 1240, alignment: .leading)
        .padding(.top, 50)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GuidePalette.background.ignoresSafeArea())
    }

    /// Where hidden categories are put back: one at a time, or all at once.
    private var hiddenRow: some View {
        let count = hiddenCategories.count
        let detail = count == 1 ? "1 hidden" : "\(count) hidden"
        return TVSelectable(scale: 1.015, drawsFocusChrome: false, action: { showingHidden = true }) {
            TVGuideCategoryRow(title: "Hidden Categories", symbol: "eye.slash", detail: detail)
        }
        .padding(.top, 22)
        .tvChoices("Hidden Categories", symbol: "eye.slash", isPresented: $showingHidden,
                   message: "Choose a category to show it in the TV Guide again.") {
            [TVChoice("Show All Categories", symbol: "eye", id: "show-all", action: onShowAll)]
                + hiddenCategories.map { category in
                    TVChoice(category.categoryName, symbol: "folder", id: "show-" + category.id) { onShow(category) }
                }
        }
        .accessibilityLabel("Hidden Categories, \(detail)")
        .accessibilityHint("Shows the categories you have hidden")
    }

    private func row(_ choice: TVGuideCategoryChoice, _ title: String, symbol: String,
                     detail: String? = nil) -> some View {
        TVSelectable(scale: 1.015, drawsFocusChrome: false, action: { choose(choice) },
                     requestInitialFocus: takesFocus && choice.id == lastChosen) {
            TVGuideCategoryRow(title: title, symbol: symbol, detail: detail)
        }
        .id(choice.id)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityHint("Opens the TV Guide on this")
    }
}

private struct TVGuideCategoryRow: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    let symbol: String
    let detail: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 20) {
            LineupIconTile(symbol: symbol, size: 44)
            Text(title)
                .font(.inter(26, .semibold))
                .lineLimit(1)
            Spacer(minLength: 20)
            if let detail {
                Text(detail).font(.inter(21)).foregroundStyle(GuidePalette.secondary).lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(GuidePalette.secondary)
        }
        .foregroundStyle(GuidePalette.text)
        .padding(.horizontal, 22)
        .frame(height: 84)
        .background(GuidePalette.surface, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// Switch between the schedule grid and the channel-first list while keeping
/// the same remote-friendly choice sheet used by the rest of tvOS.
private struct TVGuideViewModePicker: View {
    @Binding var value: String
    @State private var choosing = false

    private var selection: TVGuideViewMode { TVGuideViewMode.restored(value) }

    var body: some View {
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                     action: { choosing = true }) {
            HStack(spacing: 9) {
                Image(systemName: selection.symbol)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(LineupStyle.highlight)
                Text(selection.title).font(.inter(17, .semibold)).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(GuidePalette.channelText)
            }
            .foregroundStyle(GuidePalette.rowText)
            .padding(.horizontal, 15).frame(height: 48)
            .background(GuidePalette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(GuidePalette.line, lineWidth: 1))
        }
        .tvChoices("TV Guide View", symbol: "rectangle.grid.1x2", isPresented: $choosing) {
            TVGuideViewMode.allCases.map { mode in
                TVChoice(mode.title, symbol: mode.symbol, id: mode.rawValue,
                        isSelected: selection == mode) { value = mode.rawValue }
            }
        }
        .accessibilityLabel("View mode: \(selection.title)")
    }
}

/// A screen's name with a quiet line over it.
private struct GuideTitleBlock: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(eyebrow)
                .font(.inter(15, .heavy)).tracking(LineupPanelStyle.headerTracking)
                .foregroundStyle(LineupPanelStyle.caption).lineLimit(1)
            Text(title)
                .font(.inter(32, .bold))
                .foregroundStyle(GuidePalette.text).lineLimit(1)
        }
    }
}

/// The picture fills the left of the Guide's upper section, with its heading
/// and programme information together on the right.
private struct GuidePreviewPanel: View {
    /// The whole room previously split between the 64pt heading, an 18pt gap,
    /// and the 216pt preview. The channel grid stays at the same height.
    static let height: CGFloat = 298

    let controls: GuideControlBar
    let item: GuideFocusItem
    let categoryName: String
    let quality: String?
    let now: Date

    private var progress: CGFloat {
        let duration = item.program.end.timeIntervalSince(item.program.start)
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(now.timeIntervalSince(item.program.start) / duration, 0), 1))
    }

    /// "23 MIN LEFT", while the programme is on.
    private var remaining: String? {
        guard item.program.isLive else { return nil }
        let minutes = Int((item.program.end.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) HR \(minutes % 60) MIN LEFT" : "\(minutes) MIN LEFT"
    }

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(alignment: .top, spacing: 20) {
            // The channel's mark. Browsing never starts a stream: a picture
            // for every channel the remote rested on was a connection opened
            // and closed, and a video decoded, for each.
            GuidePreviewArtwork(stream: item.stream)
                .frame(width: Self.height * 16 / 9, height: Self.height)
            .clipShape(frame)

            VStack(alignment: .leading, spacing: 12) {
                controls
                programInfo
                Spacer(minLength: 0)
                playbackHints.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var programInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if item.program.isLive { GuideLiveTag() }
                Text(item.stream.name.uppercased())
                    .font(.inter(14, .heavy)).tracking(0.6)
                    .foregroundStyle(GuidePalette.text).lineLimit(1)
                Text(categoryName.uppercased())
                    .font(.inter(14, .heavy)).tracking(0.6)
                    .foregroundStyle(GuidePalette.secondary).lineLimit(1)
                if let quality { GuideTinyBadge(title: quality) }
                if item.program.isNew == true { GuideTinyBadge(title: "NEW") }
            }
            Text(item.program.title.isEmpty ? "Untitled" : item.program.title)
                .font(.inter(38, .bold))
                .foregroundStyle(GuidePalette.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 16) {
                Text(guideTimeRange(item.program))
                    .font(.interDigits(18, .semibold))
                    .foregroundStyle(GuidePalette.secondary)
                if item.program.isLive {
                    GuideProgressBar(progress: progress).frame(width: 220)
                    if let remaining {
                        Text(remaining)
                            .font(.inter(13, .heavy)).tracking(0.6)
                            .foregroundStyle(GuidePalette.secondary)
                    }
                }
            }
            Text(item.program.detail.isEmpty ? "No description for this program." : item.program.detail)
                .font(.inter(19))
                .foregroundStyle(GuidePalette.secondary)
                .lineLimit(2)
                .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What Select does.
    private var playbackHints: some View {
        Label("SELECT TO WATCH", systemImage: "play.fill")
            .foregroundStyle(GuidePalette.secondary.opacity(0.85))
            .font(.inter(12, .heavy)).tracking(0.6)
            .fixedSize()
            .padding(.bottom, 8)
    }
}

/// The channel's mark on a dark plate, for a channel that is not playing.
private struct GuidePreviewArtwork: View {
    let stream: XtreamStream
    var body: some View {
        ZStack {
            GuidePalette.surface
            LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 420) { loaded in
                if let image = loaded {
                    image.resizable().scaledToFit().padding(40)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tv").font(.system(size: 38, weight: .light, design: .rounded))
                        Text(stream.name).font(.inter(18, .semibold))
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(GuidePalette.secondary)
                    .padding(24)
                }
            }
            .transaction { $0.animation = nil }
        }
    }
}

/// HD, NEW and the like: a small outlined tag, never a coloured one.
private struct GuideTinyBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.inter(13, .bold)).tracking(1.2)
            .foregroundStyle(GuidePalette.secondary)
            .padding(.horizontal, 7).frame(height: 24)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(GuidePalette.secondary.opacity(0.5), lineWidth: 1))
            .fixedSize()
    }
}

private func guideQuality(_ stream: XtreamStream) -> String? {
    let value = stream.name.uppercased()
    if value.contains("4K") || value.contains("UHD") { return "UHD" }
    if value.contains("FHD") || value.contains("1080") { return "FHD" }
    if value.contains("HD") || value.contains("720") { return "HD" }
    return nil
}

private func guideTimeRange(_ program: CurrentProgram) -> String {
    "\(program.start.formatted(date: .omitted, time: .shortened)) — \(program.end.formatted(date: .omitted, time: .shortened))"
}

struct MultiviewSession: Identifiable {
    let id = UUID()
    let primary: XtreamStream
    let secondary: XtreamStream
    let primaryGame: SportsGame?
    let secondaryGame: SportsGame?
}

private struct GuideSidebar: View {
    @Environment(SportsLibrary.self) private var library
    /// Categories taken out of the Guide.
    let hidden: Set<String>
    let selectedCategoryID: String?
    let favoritesOnly: Bool
    let recentsOnly: Bool
    let focus: FocusState<String?>.Binding
    let onCollapse: () -> Void
    let choose: (TVGuideCategoryChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GuideSidebarHeading(title: "BROWSE")
            GuideSidebarButton(title: "All channels", symbol: "square.grid.2x2", selected: selectedCategoryID == nil && !favoritesOnly && !recentsOnly, focus: focus, focusID: "all") {
                choose(.all)
            }
            GuideSidebarButton(title: "Favorites", symbol: "star", selected: favoritesOnly, focus: focus, focusID: "favorites") {
                choose(.favorites)
            }
            GuideSidebarHeading(title: "CATEGORIES").padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.categories.filter { !hidden.contains($0.id) }) { category in
                        GuideSidebarButton(title: category.categoryName, symbol: "rectangle.grid.1x2", selected: selectedCategoryID == category.id && !favoritesOnly, focus: focus, focusID: "category-" + category.id) {
                            choose(.category(category.id))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6)
        .onMoveCommand { direction in
            if direction == .right { onCollapse() }
        }
        .task {
            // All channels is always mounted; do not target an offscreen lazy category.
            focus.wrappedValue = favoritesOnly ? "favorites" : "all"
        }
    }
}

struct GuideSidebarHeading: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.inter(16, .heavy)).tracking(LineupPanelStyle.headerTracking)
            .foregroundStyle(LineupPanelStyle.caption)
            .lineLimit(1)
            .padding(.leading, 16)
            .frame(height: 40, alignment: .bottomLeading)
            .padding(.bottom, 4)
    }
}

/// A leading bar marks the chosen category. A bright outline follows the remote.
struct GuideSidebarButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let focus: FocusState<String?>.Binding
    let focusID: String
    private var isFocused: Bool { focus.wrappedValue == focusID }
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 14) {
            LineupIconTile(symbol: symbol, size: 32)
            Text(title)
                .font(.inter(21, selected ? .semibold : .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(selected || isFocused ? GuidePalette.text : GuidePalette.secondary)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 50)
        .background {
            if isFocused {
                shape.fill(Color.white.opacity(0.24))
            } else if selected {
                shape.fill(GuidePalette.surface)
            }
        }
        .overlay {
            if isFocused {
                shape.strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
            }
        }
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(GuidePalette.text).frame(width: 3, height: 22)
            }
        }
        .contentShape(shape).focusable().focused(focus, equals: focusID).focusEffectDisabled().tvSelectAction(action)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct GuideHeaderButton: View {
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    var onMoveDown: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        let shape = Capsule()
        LineupTileLabel(title: title, symbol: symbol, tileSize: 32)
            .font(.inter(18, .semibold))
            .foregroundStyle(GuidePalette.text)
            .padding(.leading, 8).padding(.trailing, 22).frame(height: 48)
            .background(GuidePalette.surface, in: shape)
            .lineupFocusLayer(isFocused, in: shape, lifts: false)
            .contentShape(shape).focusable().focused($isFocused).focusEffectDisabled().tvSelectAction(action)
            .focusLift(isFocused, scale: LineupStyle.controlLift)
            .onMoveCommand { direction in if direction == .down { onMoveDown?() } }
    }
}

/// The day over the channels, and a tick and a time at every half hour.
private struct GuideTimelineHeader: View {
    @Environment(\.guideLayout) private var layout
    let now: Date

    var body: some View {
        let anchor = guideTimelineAnchor(now)
        HStack(spacing: 0) {
            // Now, at the head of the channel column, as the phone's Guide
            // has it. There is no line down the grid for it: how far each
            // programme on now has run is washed across its own cell.
            VStack(spacing: 2) {
                Text("NOW").font(.inter(13, .heavy)).tracking(0.6)
                    .foregroundStyle(GuidePalette.secondary)
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(19, .semibold))
                    .foregroundStyle(GuidePalette.text)
            }
            .lineLimit(1)
            .frame(width: layout.channelWidth)
            ForEach(0..<guideVisibleSlotCount, id: \.self) { step in
                HStack(spacing: 10) {
                    Rectangle().fill(GuidePalette.secondary.opacity(0.5)).frame(width: 1, height: 14)
                    Text(anchor.addingTimeInterval(Double(step) * 1800)
                        .formatted(date: .omitted, time: .shortened))
                        .font(.interDigits(18, .semibold))
                        .foregroundStyle(GuidePalette.secondary)
                        .lineLimit(1)
                }
                .frame(width: layout.slotWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, GuideLayout.inset)
        .frame(height: guideHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GuidePalette.line).frame(height: 1)
        }
    }
}

/// The programme grid and its time ruler share one dark leading-edge fade.
/// Keeping this overlay on the scrolling region blends each row into the
/// guide background without touching the pinned channel-logo rail.
private struct GuideEPGLeadingFade: View {
    let startX: CGFloat
    let width: CGFloat

    var body: some View {
        GeometryReader { bounds in
            LinearGradient(
                stops: [
                    .init(color: GuidePalette.background.opacity(0.96), location: 0),
                    .init(color: GuidePalette.background.opacity(0.82), location: 0.2),
                    .init(color: GuidePalette.background.opacity(0.54), location: 0.48),
                    .init(color: GuidePalette.background.opacity(0.2), location: 0.78),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width, height: bounds.size.height)
            .position(x: startX + width / 2, y: bounds.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The list has one programme column instead of a time ruler; this keeps the
/// channel and on-now information aligned to the exact same row boundaries.
private struct GuideListHeader: View {
    let now: Date
    let channelWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("CHANNEL")
                .font(.inter(13, .heavy)).tracking(0.8)
                .foregroundStyle(GuidePalette.channelText)
                .frame(width: channelWidth, alignment: .leading)
            HStack(spacing: 8) {
                GuideLiveDot(size: 7)
                Text("NOW")
                    .font(.inter(13, .heavy)).tracking(0.8)
                    .foregroundStyle(GuidePalette.channelText)
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(18, .semibold))
                    .foregroundStyle(GuidePalette.rowText)
            }
            .padding(.leading, 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GuideLayout.inset)
        .frame(height: guideHeaderHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(GuidePalette.line).frame(height: 1) }
    }
}

/// The time bar's height, which is also where the line for now begins.
private let guideHeaderHeight: CGFloat = 48

private let guideVisibleSlotCount = 6

// Grow the grid cells in both dimensions without scaling typography or artwork.
// Keep the original channel/half-hour widths and row aspect ratio in sync.
private struct GuideLayout {
    /// The grid runs nearly the screen's full width. With each row's own
    /// inset (`inset`) its logos and programmes sit 20 points from the edges.
    /// The grid scales as a whole to fill it, cells and rows in proportion,
    /// so nothing is stretched.
    static let margin: CGFloat = 6
    /// A row's own padding either side, which the standalone header takes
    /// too, so it lines up with the logos.
    static let inset: CGFloat = 14
    let width: CGFloat
    var slotWidth: CGFloat { max(1, width - 2 * Self.inset) / CGFloat(guideVisibleSlotCount + 1) }
    var channelWidth: CGFloat { slotWidth }
    var listChannelWidth: CGFloat { min(350, max(270, width * 0.2)) }
    // A guide is worth having in proportion to how much of it you can see at
    // once, and at 132 this showed four channels on a 1080 screen. Ninety-two
    // is what a row needs for a title and a time under it at this type size
    // and no more, which is six or seven channels -- enough to scan without
    // the rows becoming a list of hairlines.
    var rowHeight: CGFloat { 92 * slotWidth / 245 }
}

private struct GuideLayoutKey: EnvironmentKey {
    static let defaultValue = GuideLayout(width: 1800)
}

private extension EnvironmentValues {
    var guideLayout: GuideLayout {
        get { self[GuideLayoutKey.self] }
        set { self[GuideLayoutKey.self] = newValue }
    }
}

private func guideTimelineAnchor(_ date: Date) -> Date {
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    components.minute = ((components.minute ?? 0) / 30) * 30
    components.second = 0
    let floor = calendar.date(from: components) ?? date
    return calendar.date(byAdding: .minute, value: -30, to: floor) ?? floor
}

private struct GuideGridFocus: Hashable {
    let streamID: Int
    let programStart: Date?
}

/// Where the remote is taking focus in the guide, and which rows exist.
///
/// A class, and so not observed: it changes with every press and every row
/// scrolled past, and redrawing the guide for either would be work for
/// nothing.
private final class GuideNavigation {
    var builtRows: Set<Int> = []
    /// The list of channels, as last drawn.
    var scroll: ScrollViewProxy?
    private var target: GuideGridFocus?
    private var sentAt: TimeInterval = 0
    /// The rows focus may pass through on its way: from the row it was on
    /// when the presses began to the one they are taking it to.
    private var rows: ClosedRange<Int>?
    private var origin = 0

    func clearTarget() {
        target = nil
        rows = nil
    }

    /// - Parameters:
    ///   - row: the target's row.
    ///   - from: the row focus is on now.
    func heading(to focus: GuideGridFocus, row: Int, from: Int) {
        if headingTo() == nil { origin = from }
        target = focus
        rows = min(origin, row)...max(origin, row)
        sentAt = ProcessInfo.processInfo.systemUptime
    }

    /// Where the last press sent focus, while it may still be on its way.
    /// After that, the focused cell itself is where a press starts.
    func headingTo() -> GuideGridFocus? {
        guard ProcessInfo.processInfo.systemUptime - sentAt < 0.45 else { return nil }
        return target
    }

    /// Focus has landed on `row`. A row off the way the presses were taking
    /// it means something else moved it -- a swipe the focus engine carried
    /// further than the presses went -- and the presses' target is let go.
    /// Kept, it pulled focus back a few rows once that row was built, or
    /// the next press started from it.
    func landed(on row: Int) {
        guard target != nil, let rows, !rows.contains(row) else { return }
        clearTarget()
    }
}

// Only the first reachable cell receives a directional handler. Other cells
// remain entirely under the native tvOS focus engine's control.
private struct GuideLeftBoundary: ViewModifier {
    let enabled: Bool
    let onOpen: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onMoveCommand { direction in
                if direction == .left { onOpen() }
            }
        } else {
            content
        }
    }
}

private struct GuideChannelRow: View, Equatable {
    /// What the row is drawn from. Its actions are left out: they do the
    /// same thing for the same channel however many times they are made.
    /// Focus reaches the cells on its own, and the layout and the favourite
    /// star through the environment and the library.
    nonisolated static func == (lhs: GuideChannelRow, rhs: GuideChannelRow) -> Bool {
        lhs.stream == rhs.stream && lhs.visiblePrograms == rhs.visiblePrograms
            && lhs.favoritesMode == rhs.favoritesMode && lhs.now == rhs.now
            && (lhs.multiviewPrimaryID == lhs.stream.id) == (rhs.multiviewPrimaryID == rhs.stream.id)
    }

    @Environment(\.guideLayout) private var layout
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let visiblePrograms: [CurrentProgram]
    let favoritesMode: Bool
    let now: Date
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let focus: GuideFocusModel
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    let onReorderFavorites: () -> Void
    /// The programme on now from its start, and the channel's past
    /// programmes: for a channel the provider records.
    let onStartOver: () -> Void
    let onCatchUp: () -> Void
    let onMoveFocus: (MoveCommandDirection, GuideGridFocus) -> Void
    let onFocusProgram: (CurrentProgram) -> Void
    var body: some View {
        // Worked out once for the row rather than for each of its cells.
        let anchor = guideTimelineAnchor(now)
        let quality = guideQuality(stream)
        HStack(spacing: 0) {
            // On the guide's own ground, as on the phone: no plate behind it.
            GuideChannelArtwork(stream: stream, isFavorite: library.isFavorite(stream))
            .frame(width: layout.channelWidth - 8, height: layout.rowHeight - 8)
            .padding(.vertical, 4)
            .padding(.trailing, 8)
            .clipped()

            ZStack(alignment: .leading) {
                if visiblePrograms.isEmpty {
                    let focusID = GuideGridFocus(streamID: stream.id, programStart: nil)
                    GuideProgramCell(program: nil, empty: "No guide information", quality: quality, now: now, anchor: anchor, showsTime: true, onPlay: onPlay, onFocus: {}, gridFocus: gridFocus, focus: focus, focusID: focusID, onMove: { onMoveFocus($0, focusID) })
                        .frame(width: layout.slotWidth - 6, alignment: .leading)
                } else {
                    ForEach(visiblePrograms.indices, id: \.self) { index in
                        let program = visiblePrograms[index]
                        let width = guideProgramWidth(program, anchor: anchor, layout: layout)
                        let focusID = GuideGridFocus(streamID: stream.id, programStart: program.start)
                        GuideProgramCell(program: program, empty: "", quality: quality, now: now, anchor: anchor, showsTime: width >= 110, onPlay: onPlay, onFocus: { onFocusProgram(program) }, gridFocus: gridFocus, focus: focus, focusID: focusID, onMove: { onMoveFocus($0, focusID) })
                            .frame(width: width, alignment: .leading)
                            .offset(x: guideProgramX(program, anchor: anchor, layout: layout))
                    }
                }
            }
            .frame(width: layout.slotWidth * CGFloat(guideVisibleSlotCount), alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, GuideLayout.inset)
        .frame(width: layout.width, height: layout.rowHeight, alignment: .leading)
        .background {
            LineupChannelArtworkTint(url: stream.streamIcon.flatMap(URL.init(string:)),
                                     width: 150, fallback: GuidePalette.rail)
                .frame(width: layout.width, height: layout.rowHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        // Multiview's first channel keeps a white frame while the second is
        // chosen, so it is never mistaken for where the remote is.
        .overlay {
            if multiviewPrimaryID == stream.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(GuidePalette.text, lineWidth: 2)
                    .padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .tvHoldMenu(stream.name, symbol: "tv") {
            var items: [TVChoice] = []
            if stream.hasCatchUp {
                items.append(TVChoice("Start Over", symbol: "backward.end") { onStartOver() })
                items.append(TVChoice("Catch Up", symbol: "clock.arrow.circlepath") { onCatchUp() })
            }
            let first = multiviewPrimaryID == stream.id
            items.append(TVChoice(first ? "First Multiview Channel" : "Start Multiview", symbol: "rectangle.split.2x1",
                                  isEnabled: !first) { onStartMultiview() })
            if favoritesMode {
                items.append(TVChoice("Reorder Favorites", symbol: "arrow.up.arrow.down") { onReorderFavorites() })
                items.append(TVChoice("Move Up", symbol: "arrow.up",
                                      isEnabled: library.canMoveFavorite(stream, offset: -1)) {
                    library.moveFavorite(stream, offset: -1)
                })
                items.append(TVChoice("Move Down", symbol: "arrow.down",
                                      isEnabled: library.canMoveFavorite(stream, offset: 1)) {
                    library.moveFavorite(stream, offset: 1)
                })
                items.append(TVChoice("Remove from Favorites", symbol: "star.slash", isDestructive: true) {
                    library.removeFavorite(stream)
                })
            } else if library.isFavorite(stream) {
                items.append(TVChoice("Reorder Favorites", symbol: "arrow.up.arrow.down") { onReorderFavorites() })
                items.append(TVChoice("Remove from Favorites", symbol: "star.slash", isDestructive: true) {
                    library.removeFavorite(stream)
                })
            } else {
                items.append(TVChoice("Add to Favorites", symbol: "star") { library.addFavorite(stream) })
            }
            return items
        }
    }
}

/// A channel-first alternative to the timeline. The logo occupies the tinted
/// rail and current programme details fill the matching dark row to its right.
private struct GuideChannelListRow: View, Equatable {
    /// As the grid's rows: what is drawn, not the actions.
    nonisolated static func == (lhs: GuideChannelListRow, rhs: GuideChannelListRow) -> Bool {
        lhs.stream == rhs.stream && lhs.program == rhs.program && lhs.now == rhs.now
            && lhs.quality == rhs.quality && lhs.favoritesMode == rhs.favoritesMode
            && (lhs.multiviewPrimaryID == lhs.stream.id) == (rhs.multiviewPrimaryID == rhs.stream.id)
    }

    @Environment(\.guideLayout) private var layout
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let program: CurrentProgram?
    let now: Date
    let quality: String?
    let favoritesMode: Bool
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let focus: GuideFocusModel
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    let onReorderFavorites: () -> Void
    let onStartOver: () -> Void
    let onCatchUp: () -> Void
    let onMoveFocus: (MoveCommandDirection, GuideGridFocus) -> Void
    let onFocus: () -> Void

    private var focusID: GuideGridFocus { GuideGridFocus(streamID: stream.id, programStart: nil) }
    private var isFocused: Bool { focus.current == focusID }
    private var logoWidth: CGFloat { layout.listChannelWidth }
    private var rowHeight: CGFloat { min(128, max(106, layout.rowHeight * 0.9)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let programTitle = program.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Program guide not available"
        HStack(spacing: 0) {
            ZStack {
                LineupChannelArtworkTint(url: stream.streamIcon.flatMap(URL.init(string:)),
                                         width: 150, fallback: GuidePalette.rail)
                GuideChannelArtwork(stream: stream, isFavorite: library.isFavorite(stream))
            }
            .frame(width: logoWidth, height: rowHeight)
            .clipShape(shape)

            VStack(alignment: .leading, spacing: 9) {
                Text(programTitle)
                    .font(.inter(28, .semibold))
                    .foregroundStyle(program == nil ? GuidePalette.channelText.opacity(0.7) : GuidePalette.rowText)
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 12) {
                    if let program {
                        if program.start <= now && now < program.end {
                            HStack(spacing: 7) {
                                GuideLiveDot(size: 8)
                                Text("LIVE").foregroundStyle(LineupStyle.liveStatus)
                            }
                        } else {
                            Text(guideTimeRange(program)).foregroundStyle(GuidePalette.channelText)
                        }
                        if program.isNew == true { GuideTinyBadge(title: "NEW") }
                    }
                    if let quality { GuideTinyBadge(title: quality) }
                }
                .font(.inter(16, .heavy)).tracking(0.5)
                .foregroundStyle(GuidePalette.channelText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .background(GuidePalette.background.opacity(0.45))
        }
        .padding(.horizontal, GuideLayout.inset)
        .frame(width: layout.width, height: rowHeight, alignment: .leading)
        .background(GuidePalette.rail, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
        .lineupFocusLayer(isFocused, in: shape)
        .contentShape(shape)
        .focusable().focused(gridFocus, equals: focusID).focusEffectDisabled()
        .tvSelectAction(onPlay)
        .onMoveCommand { onMoveFocus($0, focusID) }
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
        .modifier(GuideChannelListMenu(stream: stream, favoritesMode: favoritesMode,
                                       isPrimary: multiviewPrimaryID == stream.id,
                                       onReorderFavorites: onReorderFavorites,
                                       onStartOver: onStartOver, onCatchUp: onCatchUp,
                                       onStartMultiview: onStartMultiview))
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stream.name), \(program?.title ?? "program guide not available")\(library.isFavorite(stream) ? ", favorite" : "")")
    }
}

/// Keep the Guide's long-press actions identical in List and TV Guide modes.
private struct GuideChannelListMenu: ViewModifier {
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let favoritesMode: Bool
    let isPrimary: Bool
    let onReorderFavorites: () -> Void
    let onStartOver: () -> Void
    let onCatchUp: () -> Void
    let onStartMultiview: () -> Void

    func body(content: Content) -> some View {
        content.tvHoldMenu(stream.name, symbol: "tv") {
            var items: [TVChoice] = []
            if stream.hasCatchUp {
                items.append(TVChoice("Start Over", symbol: "backward.end", action: onStartOver))
                items.append(TVChoice("Catch Up", symbol: "clock.arrow.circlepath", action: onCatchUp))
            }
            items.append(TVChoice(isPrimary ? "First Multiview Channel" : "Start Multiview",
                                  symbol: "rectangle.split.2x1", isEnabled: !isPrimary,
                                  action: onStartMultiview))
            if favoritesMode {
                items.append(TVChoice("Reorder Favorites", symbol: "arrow.up.arrow.down", action: onReorderFavorites))
                items.append(TVChoice("Move Up", symbol: "arrow.up",
                                      isEnabled: library.canMoveFavorite(stream, offset: -1)) {
                    library.moveFavorite(stream, offset: -1)
                })
                items.append(TVChoice("Move Down", symbol: "arrow.down",
                                      isEnabled: library.canMoveFavorite(stream, offset: 1)) {
                    library.moveFavorite(stream, offset: 1)
                })
                items.append(TVChoice("Remove from Favorites", symbol: "star.slash", isDestructive: true) {
                    library.removeFavorite(stream)
                })
            } else if library.isFavorite(stream) {
                items.append(TVChoice("Reorder Favorites", symbol: "arrow.up.arrow.down", action: onReorderFavorites))
                items.append(TVChoice("Remove from Favorites", symbol: "star.slash", isDestructive: true) {
                    library.removeFavorite(stream)
                })
            } else {
                items.append(TVChoice("Add to Favorites", symbol: "star") { library.addFavorite(stream) })
            }
            return items
        }
    }
}

/// A channel as the guide names it: its logo, its name under it, and a small
/// star in the corner if it is a favourite, as on the phone. Where there is no
/// logo, a quiet television mark holds its place so every name sits on the
/// same line.
private struct GuideChannelArtwork: View {
    let stream: XtreamStream
    let isFavorite: Bool

    var body: some View {
        VStack(spacing: 6) {
            LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 120) { loaded in
                if let image = loaded {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 20, weight: .regular, design: .rounded))
                        .foregroundStyle(GuidePalette.secondary)
                }
            }
            .transaction { $0.animation = nil }
            .frame(width: 120, height: 36)
            Text(stream.name)
                .font(.inter(16, .semibold))
                .foregroundStyle(GuidePalette.channelText)
                .lineLimit(1).minimumScaleFactor(0.8)
                .allowsTightening(true)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(GuidePalette.text)
                    .padding(9)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Remote-friendly freeform ordering: select a channel to pick it up, focus any
/// destination, then select again to drop it at that position.
private struct TVFavoritesOrderView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var pickedStreamID: Int?
    @FocusState private var focusedStreamID: Int?

    private var favorites: [XtreamStream] {
        library.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
    }

    var body: some View {
        ZStack {
            LineupPresentationStyle.ground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR CHANNELS")
                            .font(.inter(13, .heavy)).tracking(0.6)
                            .foregroundStyle(LineupPresentationStyle.secondary)
                        Text("Arrange Favorites")
                            .font(.inter(46, .bold))
                        Text(instruction)
                            .font(.inter(.title3))
                            .foregroundStyle(LineupPresentationStyle.secondary)
                            .contentTransition(.opacity)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Label("\(favorites.count) FAVORITES", systemImage: "star.fill")
                            .font(.inter(.caption, .bold)).tracking(1.2)
                            .padding(.horizontal, 16).frame(height: 46)
                            .nullGlass(clear: true, cornerRadius: 23)
                        TVReorderDoneButton { dismiss() }
                    }
                }

                Group {
                    if favorites.isEmpty {
                        LineupUnavailableView("No favorites", systemImage: "star",
                            description: Text("Add channels to Favorites from the TV Guide."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(Array(favorites.enumerated()), id: \.element.id) { index, stream in
                                        favoriteRow(stream, position: index + 1)
                                            .id(stream.id)
                                    }
                                }
                                .padding(.horizontal, 28).padding(.vertical, 26)
                            }
                            .scrollClipDisabled()
                            .onChange(of: focusedStreamID) { _, streamID in
                                guard let streamID else { return }
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    proxy.scrollTo(streamID, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .background(GuidePalette.rail, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(GuidePalette.line, lineWidth: 1))
            }
            .padding(.horizontal, 86).padding(.vertical, 58)
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .task {
            if focusedStreamID == nil { focusedStreamID = favorites.first?.id }
        }
        .onExitCommand {
            if pickedStreamID != nil { pickedStreamID = nil }
            else { dismiss() }
        }
    }

    private var instruction: String {
        if let pickedStreamID, let stream = favorites.first(where: { $0.id == pickedStreamID }) {
            return "Moving \(stream.name)  ·  Choose any destination and press Select to place it."
        }
        return "Select a channel, move anywhere in the list, then Select again to place it."
    }

    private func favoriteRow(_ stream: XtreamStream, position: Int) -> some View {
        let isPicked = pickedStreamID == stream.id
        let isFocused = focusedStreamID == stream.id
        return HStack(spacing: 22) {
            ZStack {
                Circle().fill(isPicked ? LineupPresentationStyle.text : LineupPresentationStyle.row)
                Text("\(position)").font(.interDigits(.callout, .bold))
                    .foregroundStyle(isPicked ? GuidePalette.background : LineupPresentationStyle.secondary)
            }
            .frame(width: 44, height: 44)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LineupPresentationStyle.row.opacity(0.82))
                LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 100) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit().padding(10)
                    } else {
                        Image(systemName: "tv").foregroundStyle(LineupPresentationStyle.secondary)
                    }
                }
                .transaction { $0.animation = nil }
            }
            .frame(width: 100, height: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(stream.name).font(.inter(.title3, .semibold)).lineLimit(1)
                Text(isPicked ? "Ready to move" : "Favorite channel")
                    .font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            Spacer()
            if isPicked {
                Label("PICKED UP", systemImage: "hand.draw.fill")
                    .font(.inter(.caption, .bold)).tracking(1.2)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(LineupStyle.lightPurple, in: Capsule())
                    .foregroundStyle(GuidePalette.background)
            } else if pickedStreamID != nil && isFocused {
                Label("PLACE HERE", systemImage: "arrow.down.to.line")
                    .font(.inter(.caption, .bold)).tracking(1.2)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(LineupStyle.lightPurple.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 88)
        .background(isPicked ? GuidePalette.raised : GuidePalette.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
            isPicked ? LineupPresentationStyle.text : LineupStyle.line,
            lineWidth: isPicked ? 2 : 1
        ))
        .lineupFocusLayer(isFocused && !isPicked, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            if pickedStreamID != nil && isFocused && !isPicked {
                Capsule().fill(LineupPresentationStyle.text).frame(width: 4, height: 44).offset(x: -2)
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focusedStreamID, equals: stream.id)
        .focusEffectDisabled()
        .onTapGesture { select(stream) }
        // Smaller than either standard step, and deliberately so: these cells
        // sit shoulder to shoulder in a grid, and a card step here would push
        // one over its neighbours rather than above them.
        .scaleEffect(isPicked ? 1.025 : (isFocused ? 1.012 : 1))
        .offset(y: isPicked ? -3 : 0)
        .lineupShadow(.lifted, on: isPicked || isFocused)
        .zIndex(isPicked ? 2 : (isFocused ? 1 : 0))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isPicked)
    }

    private func select(_ stream: XtreamStream) {
        guard let pickedStreamID else {
            self.pickedStreamID = stream.id
            return
        }
        guard pickedStreamID != stream.id else {
            self.pickedStreamID = nil
            return
        }
        guard let source = favorites.firstIndex(where: { $0.id == pickedStreamID }),
              let destination = favorites.firstIndex(where: { $0.id == stream.id }) else {
            self.pickedStreamID = nil
            return
        }
        library.moveFavorites(favorites, fromOffsets: IndexSet(integer: source),
            toOffset: destination > source ? destination + 1 : destination)
        self.pickedStreamID = nil
        focusedStreamID = pickedStreamID
    }
}

private struct TVReorderDoneButton: View {
    @FocusState private var focused: Bool
    let action: () -> Void

    var body: some View {
        Label("Done", systemImage: "checkmark")
            .font(.inter(.callout, .semibold))
            .padding(.horizontal, 22).frame(height: 48)
            .background(LineupPresentationStyle.card, in: Capsule())
            .foregroundStyle(LineupPresentationStyle.text)
            .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 1))
            .lineupFocusLayer(focused, in: Capsule(), lifts: false)
            .contentShape(Capsule())
            .focusable().focused($focused).focusEffectDisabled()
            .tvSelectAction(action)
            .focusLift(focused, scale: LineupStyle.controlLift)
    }
}

private func guideProgramX(_ program: CurrentProgram, anchor: Date, layout: GuideLayout) -> CGFloat {
    let visibleStart = max(program.start, anchor)
    return max(0, CGFloat(visibleStart.timeIntervalSince(anchor) / 1800) * layout.slotWidth)
}

private func guideProgramWidth(_ program: CurrentProgram, anchor: Date, layout: GuideLayout) -> CGFloat {
    let windowEnd = anchor.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
    let visibleStart = max(program.start, anchor)
    let visibleEnd = min(program.end, windowEnd)
    let durationWidth = CGFloat(max(0, visibleEnd.timeIntervalSince(visibleStart)) / 1800) * layout.slotWidth
    return max(1, durationWidth - 6)
}

/// A programme block spans its full scheduled time. Elapsed time adds a wash
/// over the card so the rest of the programme still reads as part of the grid.
///
/// Every cell on screen is asked again each time the remote moves, since
/// each has to say whether it is the one in focus. What it shows is a view
/// of its own (`GuideProgramFace`) that only its programme and the time
/// change, so a move costs each cell a comparison and the two that changed
/// a border, not thirty titles and time ranges set again.
private struct GuideProgramCell: View {
    let program: CurrentProgram?
    let empty: String
    let quality: String?
    let now: Date
    /// Where the grid's first column starts.
    let anchor: Date
    let showsTime: Bool
    let onPlay: () -> Void
    let onFocus: () -> Void
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let focus: GuideFocusModel
    let focusID: GuideGridFocus
    let onMove: (MoveCommandDirection) -> Void
    private var isFocused: Bool { focus.current == focusID }

    private var isOnNow: Bool {
        guard let program else { return false }
        return program.start <= now && now < program.end
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        GuideProgramFace(program: program, empty: empty, quality: quality, now: now, anchor: anchor,
                         showsTime: showsTime)
            .equatable()
        // The programme the remote is on rises off the row, as everything
        // focused in the app does; nothing is drawn round it.
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(GuidePalette.raised)
            }
        }
        .scaleEffect(isFocused ? 1.06 : 1)
        .lineupShadow(.lifted, on: isFocused)
        .zIndex(isFocused ? 2 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isFocused)
        .contentShape(Rectangle()).focusable().focused(gridFocus, equals: focusID).focusEffectDisabled().tvSelectAction(onPlay)
        .onMoveCommand(perform: onMove)
        .accessibilityValue(isOnNow ? "On now" : "")
        // Keep the focused block in timeline coordinates so its fill stays aligned.
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
    }
}

/// What a programme block shows: its title, its times, and how far it has
/// run. Nothing here knows where the remote is.
private struct GuideProgramFace: View, Equatable {
    @Environment(\.guideLayout) private var layout
    let program: CurrentProgram?
    let empty: String
    let quality: String?
    let now: Date
    let anchor: Date
    let showsTime: Bool

    nonisolated static func == (lhs: GuideProgramFace, rhs: GuideProgramFace) -> Bool {
        lhs.program == rhs.program && lhs.empty == rhs.empty && lhs.quality == rhs.quality
            && lhs.now == rhs.now && lhs.anchor == rhs.anchor && lhs.showsTime == rhs.showsTime
    }

    private var isOnNow: Bool {
        guard let program else { return false }
        return program.start <= now && now < program.end
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            if let program {
                HStack(spacing: 8) {
                    Text(program.title.isEmpty ? "Untitled" : program.title)
                        .font(.inter(23, .semibold))
                        .foregroundStyle(GuidePalette.rowText)
                        .lineLimit(1)
                    if program.isNew == true { GuideTinyBadge(title: "NEW") }
                }
                if showsTime || isOnNow {
                    HStack(spacing: 8) {
                        if isOnNow {
                            GuideLiveDot(size: 8)
                            Text("LIVE")
                                .font(.inter(16, .semibold)).tracking(1.2)
                                .foregroundStyle(LineupStyle.liveStatus)
                        }
                        if showsTime {
                            Text(guideTimeRange(program))
                                .font(.interDigits(17, .medium))
                                .foregroundStyle(GuidePalette.secondary)
                                .lineLimit(1)
                            if let quality { GuideTinyBadge(title: quality) }
                        }
                    }
                }
            } else {
                Text(empty).font(.inter(20)).foregroundStyle(GuidePalette.channelText)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.rowHeight - 8, alignment: .topLeading)
        .background {
            ZStack(alignment: .leading) {
                shape.fill(Color.white.opacity(program == nil ? 0.04 : 0.085))
                if let program, isOnNow {
                    GeometryReader { geometry in
                        let played = GuideProgress.playedWidth(
                            start: program.start, end: program.end, now: now,
                            visibleStart: anchor,
                            pointsPerSecond: Double(layout.slotWidth) / 1800,
                            cellWidth: Double(geometry.size.width))
                        // A low-contrast wash, not a second progress bar; its
                        // edge still ends where the timeline says now is.
                        Rectangle()
                            .fill(GuidePalette.rowText.opacity(0.10))
                            .frame(width: CGFloat(played), height: geometry.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }
            .clipShape(shape)
        }
    }
}

/// On air, as the app's small red dot.
private struct GuideLiveDot: View {
    var size: CGFloat = 10

    var body: some View {
        PulsingLiveDot(size: size)
    }
}

/// The dot and the word, for the preview of a programme on now.
private struct GuideLiveTag: View {
    var body: some View {
        HStack(spacing: 7) {
            GuideLiveDot(size: 10)
            Text("LIVE")
                .font(.inter(14, .heavy)).tracking(0.6)
                .foregroundStyle(LineupStyle.liveStatus)
        }
    }
}

private struct GuideProgressBar: View {
    let progress: CGFloat

    var body: some View {
        LineupProgressBar(value: Double(progress), height: 10)
    }
}
