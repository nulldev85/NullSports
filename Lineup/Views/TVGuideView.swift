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
    /// The channel's artwork supplies the row background. Programme cells
    /// reveal that same colour, with only elapsed progress filled over it.
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
    var isActive = true
    @FocusState private var gridFocus: GuideGridFocus?
    @FocusState private var sidebarFocus: String?
    @State private var returnGridFocus: GuideGridFocus?
    @State private var selectedCategoryID: String?
    @State private var favoritesOnly = true
    @AppStorage(TVGuideViewMode.storageKey) private var guideViewModeValue = TVGuideViewMode.defaultMode.rawValue
    @State private var searchActive = false
    @State private var query = ""
    /// What is full screen, with the preview's player when it carries on;
    /// see the Live tab's.
    @State private var fullScreen: TVFullScreenItem?
    @State private var multiviewPrimary: XtreamStream?
    @State private var multiviewSession: MultiviewSession?
    @State private var guideNow = Date()
    @State private var focusedGuideItem: GuideFocusItem?
    /// The channel playing in the preview. Resting on a channel plays it
    /// there without sound; Select turns its sound on, and Select again
    /// takes it full screen.
    @State private var previewPlaybackStream: XtreamStream?
    @State private var pinnedPreviewItem: GuideFocusItem?
    /// Whether the preview's sound is on: only once its channel is chosen.
    @State private var previewAudible = false
    /// Waits for the remote to rest on a channel before playing it, so
    /// passing through rows doesn't open a stream for each.
    @State private var hoverTask: Task<Void, Never>?
    @State private var playbackTransitionID: UUID?
    /// What the preview goes back to playing when full screen closes.
    ///
    /// Going full screen tears the preview's player down first -- two players
    /// on one channel is two connections to the provider for one picture --
    /// so on the way back there is nothing left running to return to. This is
    /// what was pinned when it left, kept so it can be put back.
    @State private var resumeAfterFullscreen: GuideFocusItem?
    /// The channel full screen moved to, if the viewer changed channel
    /// there: the preview picks it up when full screen closes.
    @State private var fullScreenChannel: XtreamStream?
    /// A channel whose past programmes are being chosen from.
    @State private var catchUpChannel: XtreamStream?
    /// The preview's one player, kept for as long as the Guide is. Resting
    /// on a channel opens it there and moving on stops it; nothing is built
    /// or torn down as the remote moves (see `GuidePreviewVideo`).
    @StateObject private var previewPlayer = TVPlaybackController(place: .guide)
    @State private var previewHidden = false
    @State private var sidebarVisible = false
    @State private var reorderingFavorites = false
    /// Where the remote is taking focus, and which rows exist to take it.
    @State private var navigation = GuideNavigation()
    private var filtered: [XtreamStream] {
        library.guideStreams(categoryID: searchActive ? nil : selectedCategoryID, favoritesOnly: searchActive ? false : favoritesOnly, query: query)
    }
    private var selectedTitle: String {
        if favoritesOnly { return "Favorites" }
        return library.categories.first { $0.id == selectedCategoryID }?.categoryName ?? "All channels"
    }
    private var guideViewMode: TVGuideViewMode { TVGuideViewMode.restored(guideViewModeValue) }
    private var previewItem: GuideFocusItem? {
        if let focusedGuideItem, filtered.contains(where: { $0.id == focusedGuideItem.stream.id }) {
            return focusedGuideItem
        }
        for stream in filtered {
            if let program = library.guidePrograms(for: stream).first(where: { $0.start <= guideNow && guideNow < $0.end }) {
                return GuideFocusItem(stream: stream, program: program)
            }
        }
        return nil
    }
    private var displayedPreviewItem: GuideFocusItem? {
        previewPlaybackStream == nil ? previewItem : pinnedPreviewItem
    }

    private var controlBar: GuideControlBar {
        GuideControlBar(
            title: selectedTitle,
            channelCount: filtered.count,
            searchActive: $searchActive,
            query: $query,
            multiviewTitle: multiviewPrimary?.name,
            now: guideNow,
            guideViewModeValue: $guideViewModeValue,
            selectedCategoryID: $selectedCategoryID,
            favoritesOnly: $favoritesOnly,
            onCancelMultiview: { multiviewPrimary = nil }
        )
    }

    var body: some View {
        GeometryReader { container in
            let layout = GuideLayout(width: container.size.width - 2 * GuideLayout.margin)
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    if !previewHidden, let previewItem = displayedPreviewItem {
                        GuidePreviewPanel(
                            player: previewPlayer,
                            controls: controlBar,
                            item: previewItem,
                            categoryName: library.categories.first(where: { $0.id == previewItem.stream.categoryID })?.categoryName ?? "Live TV",
                            quality: guideQuality(previewItem.stream),
                            previewURLs: previewPlaybackStream?.id == previewItem.stream.id ? library.playbackURLs(for: previewItem.stream) : nil,
                            audible: previewAudible,
                            now: guideNow
                        )
                        .frame(height: GuidePreviewPanel.height)
                        // The video reaches the screen's left edge; the info
                        // pane keeps the Guide's readable inset on the right.
                        .padding(.leading, -GuideLayout.margin)
                        .padding(.trailing, GuideLayout.inset)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        controlBar.padding(.horizontal, GuideLayout.inset)
                    }

                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            if guideViewMode == .tvGuide {
                                GuideTimelineHeader(now: guideNow)
                            } else {
                                GuideListHeader(now: guideNow, channelWidth: layout.listChannelWidth)
                            }
                            if filtered.isEmpty {
                                Label(favoritesOnly ? "Your favorite channels will appear here." : "No channels in this category.",
                                      systemImage: favoritesOnly ? "star" : "rectangle.stack")
                                    .font(.inter(22, .medium)).foregroundStyle(GuidePalette.secondary)
                                    .padding(.top, 28).padding(.leading, 14)
                                    .focusable()
                                    .focused($gridFocus, equals: GuideGridFocus(streamID: -1, programStart: nil))
                                    .modifier(GuideLeftBoundary(enabled: !sidebarVisible && !searchActive, onOpen: openSidebar))
                            } else {
                                ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(filtered) { stream in
                                            let programs = visibleGuidePrograms(for: stream)
                                            let currentProgram = programs.first { $0.start <= guideNow && guideNow < $0.end }
                                            Group {
                                                if guideViewMode == .tvGuide {
                                                    GuideChannelRow(
                                                        stream: stream,
                                                        favoritesMode: favoritesOnly && !searchActive,
                                                        now: guideNow,
                                                        gridFocus: $gridFocus,
                                                        multiviewPrimaryID: multiviewPrimary?.id,
                                                        onPlay: { select(stream) },
                                                        onStartMultiview: { multiviewPrimary = stream },
                                                        onReorderFavorites: { reorderingFavorites = true },
                                                        onStartOver: { watchRecording(of: stream, programme: nil) },
                                                        onCatchUp: { catchUpChannel = stream },
                                                        onMoveFocus: { direction, focus in
                                                            moveGuideFocus(direction, from: focus, proxy: proxy)
                                                        },
                                                        onFocusProgram: { program in
                                                            focusedGuideItem = GuideFocusItem(stream: stream, program: program)
                                                            previewHidden = false
                                                        }
                                                    )
                                                } else {
                                                    GuideChannelListRow(
                                                        stream: stream,
                                                        program: currentProgram,
                                                        now: guideNow,
                                                        quality: guideQuality(stream),
                                                        favoritesMode: favoritesOnly && !searchActive,
                                                        gridFocus: $gridFocus,
                                                        multiviewPrimaryID: multiviewPrimary?.id,
                                                        onPlay: { select(stream) },
                                                        onStartMultiview: { multiviewPrimary = stream },
                                                        onReorderFavorites: { reorderingFavorites = true },
                                                        onStartOver: { watchRecording(of: stream, programme: nil) },
                                                        onCatchUp: { catchUpChannel = stream },
                                                        onMoveFocus: { direction, focus in
                                                            moveGuideListFocus(direction, from: focus, proxy: proxy)
                                                        },
                                                        onFocus: {
                                                            focusedGuideItem = currentProgram.map { GuideFocusItem(stream: stream, program: $0) }
                                                            previewHidden = false
                                                        }
                                                    )
                                                }
                                            }
                                            .id(stream.id)
                                            .onAppear { rowBuilt(stream.id) }
                                            .onDisappear { navigation.builtRows.remove(stream.id) }
                                        }
                                    }.padding(.top, 2)
                                }
                                .onChange(of: sidebarVisible) { _, visible in
                                    guard !visible, let target = gridFocus else { return }
                                    proxy.scrollTo(target.streamID, anchor: .center)
                                    Task { @MainActor in
                                        await Task.yield()
                                        guard !sidebarVisible else { return }
                                        gridFocus = target
                                    }
                                }
                                }
                            }
                        }
                        .disabled(sidebarVisible && !searchActive)
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
                                selectedCategoryID: $selectedCategoryID,
                                favoritesOnly: $favoritesOnly,
                                focus: $sidebarFocus,
                                onCollapse: closeSidebar
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
                // Only the preview coming and going is animated. Focus moving
                // through the grid never is.
                .animation(.easeOut(duration: 0.18), value: previewHidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(.container, edges: .bottom)
                .background(GuidePalette.background.ignoresSafeArea())
                .lineupFullScreenCover(item: $fullScreen, onDismiss: resumePreview) { item in
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
                        onChannelChange: { fullScreenChannel = $0 },
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
                .task(id: isActive) {
                    guard isActive else { return }
                    while !Task.isCancelled {
                        guideNow = Date()
                        do { try await Task.sleep(for: .seconds(5)) }
                        catch { return }
                    }
                }
                .onChange(of: gridFocus?.streamID) { _, streamID in rest(on: streamID) }
                .onChange(of: guideViewModeValue) { _, value in restoreGuideFocus(for: value) }
                .onChange(of: selectedCategoryID) { _, _ in restoreFilteredGuideFocus() }
                .onChange(of: favoritesOnly) { _, _ in restoreFilteredGuideFocus() }
                .onChange(of: searchActive) { _, _ in restoreFilteredGuideFocus() }
                .onChange(of: query) { _, _ in restoreFilteredGuideFocus() }
                // Away from the Guide nothing plays, and coming back to it
                // plays nothing until the remote rests on a channel.
                .onChange(of: isActive) { _, active in
                    guard !active else { return }
                    hoverTask?.cancel()
                    stopPreview()
                }
                .onExitCommand {
                    if playbackTransitionID != nil {
                        // Menu during the handover: full screen never opens, so
                        // there is nothing to come back from and nothing to
                        // keep. Left set, this would hold a channel that was
                        // never handed anywhere.
                        playbackTransitionID = nil
                        resumeAfterFullscreen = nil
                    } else if previewPlaybackStream != nil {
                        hoverTask?.cancel()
                        stopPreview()
                    } else if !previewHidden {
                        previewHidden = true
                    }
                }
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
        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = true }
    }

    private func closeSidebar() {
        sidebarFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false }
        let channels = filtered
        let stream = returnGridFocus.flatMap { previous in channels.first { $0.id == previous.streamID } } ?? channels.first
        guard let stream else {
            gridFocus = GuideGridFocus(streamID: -1, programStart: nil)
            return
        }
        let anchor = guideTimelineAnchor(guideNow)
        let end = anchor.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        let programs = library.guidePrograms(for: stream).filter { $0.end > anchor && $0.start < end }
        if guideViewMode == .list {
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: nil)
        } else {
            let restored = programs.first { $0.start == returnGridFocus?.programStart } ?? programs.first
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: restored?.start)
        }
    }

    private func restoreGuideFocus(for rawValue: String) {
        guard let stream = filtered.first(where: { $0.id == gridFocus?.streamID }) ?? filtered.first else { return }
        guard TVGuideViewMode.restored(rawValue) == .tvGuide else {
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: nil)
            return
        }
        let programs = visibleGuidePrograms(for: stream)
        let current = programs.first { $0.start <= guideNow && guideNow < $0.end } ?? programs.first
        gridFocus = GuideGridFocus(streamID: stream.id, programStart: current?.start)
    }

    private func restoreFilteredGuideFocus() {
        guard !filtered.contains(where: { $0.id == gridFocus?.streamID }), let first = filtered.first else { return }
        if guideViewMode == .list {
            gridFocus = GuideGridFocus(streamID: first.id, programStart: nil)
        } else {
            let programs = visibleGuidePrograms(for: first)
            let program = programs.first { $0.start <= guideNow && guideNow < $0.end } ?? programs.first
            gridFocus = GuideGridFocus(streamID: first.id, programStart: program?.start)
        }
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
        guard let row = filtered.firstIndex(where: { $0.id == source.streamID }) else { return }

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
        guard let row = filtered.firstIndex(where: { $0.id == source.streamID }) else { return }
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
        navigation.heading(to: target)
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
        guard let target = navigation.headingTo(), target.streamID == streamID,
              !sidebarVisible, gridFocus != target else { return }
        gridFocus = target
    }

    private func visibleGuidePrograms(for stream: XtreamStream) -> [CurrentProgram] {
        let start = guideTimelineAnchor(guideNow)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        return library.guidePrograms(for: stream)
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    /// Put the preview back on the channel that was just full screen.
    ///
    /// It keeps playing there until a different channel is chosen, which is
    /// the branch below that pins a new one. Choosing the same channel again
    /// goes back to full screen, as it did before.
    ///
    /// Only for a preview that could not be lent to full screen. One that
    /// was carries on playing behind it and needs nothing put back.
    private func resumePreview() {
        previewHidden = false
        // Moved to another channel in full screen: that channel carries on
        // here, with its sound, as the one being watched.
        if let changed = fullScreenChannel {
            fullScreenChannel = nil
            resumeAfterFullscreen = nil
            hoverTask?.cancel()
            startPreview(changed, audible: true)
            return
        }
        guard let resume = resumeAfterFullscreen else { return }
        resumeAfterFullscreen = nil
        pinnedPreviewItem = resume
        // It was being watched full screen, so it comes back with its sound.
        previewAudible = true
        previewPlaybackStream = resume.stream
    }

    /// The remote resting on a channel: once it has stayed a moment, the
    /// channel plays in the preview without sound. Moving to another channel
    /// stops the one playing at once, so the preview never shows a channel
    /// the remote has left.
    private func rest(on streamID: Int?) {
        hoverTask?.cancel()
        guard let streamID, streamID != -1, isActive, multiviewPrimary == nil,
              previewPlaybackStream?.id != streamID else { return }
        if previewPlaybackStream != nil { stopPreview() }
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard gridFocus?.streamID == streamID, previewPlaybackStream == nil,
                  let stream = filtered.first(where: { $0.id == streamID }) else { return }
            startPreview(stream, audible: false)
        }
    }

    private func startPreview(_ stream: XtreamStream, audible: Bool) {
        let program = focusedGuideItem.flatMap { $0.stream.id == stream.id ? $0.program : nil }
            ?? library.guidePrograms(for: stream).normalizedEPG().first(where: { $0.start <= guideNow && guideNow < $0.end })
            ?? library.guidePrograms(for: stream).normalizedEPG().first
            ?? CurrentProgram(
                channelID: stream.epgChannelID ?? String(stream.id),
                title: stream.name,
                detail: "Live channel preview",
                start: guideNow,
                end: guideNow.addingTimeInterval(3600)
            )
        pinnedPreviewItem = GuideFocusItem(stream: stream, program: program)
        previewAudible = audible
        previewPlaybackStream = stream
        previewHidden = false
    }

    private func stopPreview() {
        previewPlaybackStream = nil
        pinnedPreviewItem = nil
        previewAudible = false
    }

    /// A channel's recording full screen: a programme from the past, or with
    /// none, the programme on now from its start. The preview's stream is
    /// let go first -- two streams of one channel is two connections.
    private func watchRecording(of stream: XtreamStream, programme: CatchUpProgramme?) {
        hoverTask?.cancel()
        stopPreview()
        fullScreenChannel = nil
        playbackTransitionID = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            fullScreen = TVFullScreenItem(stream: stream, recording: programme, startsOver: programme == nil)
        }
    }

    /// Select on a channel: playing without sound, its sound comes on;
    /// with its sound on, it goes full screen; not playing yet, it starts
    /// with its sound.
    private func select(_ stream: XtreamStream) {
        guard let primary = multiviewPrimary else {
            hoverTask?.cancel()
            if previewPlaybackStream?.id == stream.id, !previewAudible {
                previewAudible = true
            } else if previewPlaybackStream?.id == stream.id, let preview = TVPreviewHandoff.lend(playing: stream.id) {
                // The preview's own player goes full screen, still playing,
                // and the preview stays pinned behind it to come back to.
                playbackTransitionID = nil
                presentWithoutAnimation { fullScreen = TVFullScreenItem(stream: stream, preview: preview) }
            } else if previewPlaybackStream?.id == stream.id {
                let transitionID = UUID()
                playbackTransitionID = transitionID
                // Remember what is being handed to full screen, so closing it
                // comes back to this channel still playing rather than to a
                // dark panel and a channel that has to be chosen again.
                resumeAfterFullscreen = pinnedPreviewItem
                previewPlaybackStream = nil
                pinnedPreviewItem = nil
                previewHidden = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard playbackTransitionID == transitionID else { return }
                    playbackTransitionID = nil
                    fullScreen = TVFullScreenItem(stream: stream)
                }
            } else {
                playbackTransitionID = nil
                startPreview(stream, audible: true)
            }
            return
        }
        guard primary.id != stream.id else { return }
        // The two pictures open their own streams; the preview's would be a
        // third connection for nothing.
        stopPreview()
        multiviewPrimary = nil
        multiviewSession = MultiviewSession(primary: primary, secondary: stream,
                                           primaryGame: nil, secondaryGame: nil)
    }
}

private struct GuideFocusItem: Equatable {
    let stream: XtreamStream
    let program: CurrentProgram
}

private struct GuideControlBar: View {
    let title: String
    let channelCount: Int
    @Binding var searchActive: Bool
    @Binding var query: String
    let multiviewTitle: String?
    let now: Date
    @Binding var guideViewModeValue: String
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool
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
                GuideChannelFilterPicker(title: title,
                                         selectedCategoryID: $selectedCategoryID,
                                         favoritesOnly: $favoritesOnly)
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

/// Favorites and IPTV categories sit in the Guide's top control row, with the
/// left-edge sidebar kept as an alternate way to browse on the remote.
private struct GuideChannelFilterPicker: View {
    @Environment(SportsLibrary.self) private var library
    let title: String
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool
    @State private var choosing = false

    private var currentTitle: String { favoritesOnly ? "Favorites" : title }

    var body: some View {
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                     action: { choosing = true }) {
            HStack(spacing: 9) {
                Image(systemName: favoritesOnly ? "star.fill" : "tv")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(favoritesOnly ? LineupStyle.highlight : GuidePalette.channelText)
                Text(currentTitle).font(.inter(18, .semibold)).lineLimit(1).frame(maxWidth: 250)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(GuidePalette.channelText)
            }
            .foregroundStyle(GuidePalette.rowText)
            .padding(.horizontal, 16).frame(height: 48)
            .background(GuidePalette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(GuidePalette.line, lineWidth: 1))
        }
        .tvChoices("TV Guide Channels", symbol: "tv", isPresented: $choosing) {
            [
                TVChoice("All Channels", symbol: "tv", id: "all",
                        isSelected: selectedCategoryID == nil && !favoritesOnly) {
                    selectedCategoryID = nil
                    favoritesOnly = false
                },
                TVChoice("Favorites", symbol: "star", id: "favorites", isSelected: favoritesOnly) {
                    selectedCategoryID = nil
                    favoritesOnly = true
                }
            ] + library.categories.map { category in
                TVChoice(category.categoryName, symbol: "rectangle.grid.1x2", id: "category-\(category.id)",
                         isSelected: selectedCategoryID == category.id && !favoritesOnly) {
                    selectedCategoryID = category.id
                    favoritesOnly = false
                }
            }
        }
        .accessibilityLabel("TV Guide channels: \(currentTitle)")
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

    let player: TVPlaybackController
    let controls: GuideControlBar
    let item: GuideFocusItem
    let categoryName: String
    let quality: String?
    let previewURLs: [URL]?
    /// Whether the playing channel's sound is on.
    let audible: Bool
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
            Group {
                if let previewURLs {
                    GuidePreviewVideo(controller: player, channelID: item.stream.id,
                                      urls: previewURLs, audible: audible)
                } else {
                    GuidePreviewArtwork(stream: item.stream)
                }
            }
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

    /// Beside the picture, never over it: what Select does next.
    private var playbackHints: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if previewURLs != nil {
                Label(audible ? "SELECT FOR FULL SCREEN" : "SELECT FOR SOUND",
                      systemImage: audible ? "arrow.up.left.and.arrow.down.right" : "speaker.slash.fill")
                    .foregroundStyle(GuidePalette.text.opacity(0.85))
            }
            Text("MENU HIDES THE PREVIEW")
                .foregroundStyle(GuidePalette.secondary.opacity(0.8))
        }
        .font(.inter(12, .heavy)).tracking(0.6)
        .fixedSize()
        .padding(.bottom, 8)
    }
}

/// The Guide's preview picture: the Guide's one player, on the channel the
/// remote rests on.
///
/// It used to be a player of its own for every channel, built as the remote
/// rested and thrown away as it moved on. Throwing a player away while its
/// stream is still closing is what froze the screen: VLC finishes the close
/// before the player can go, and parts of that wait on the main thread, so a
/// slow stream held the whole Guide still for a second or two. One player
/// that changes channel is never thrown away mid-close.
private struct GuidePreviewVideo: View {
    @ObservedObject var controller: TVPlaybackController
    let channelID: Int
    let urls: [URL]
    /// Silent while the remote only rests on the channel; on once chosen.
    let audible: Bool

    var body: some View {
        TVHostedSurface(controller: controller)
            .overlay(alignment: .bottomLeading) { TVPreviewFormatBadges(controller: controller) }
            .overlay { TVPlaybackStatus(controller: controller) }
            .background(Color.black)
            .onAppear { open() }
            .onChange(of: channelID) { _, _ in open() }
            // Chosen: the same stream carries on, its sound turned on.
            .onChange(of: audible) { _, on in controller.setMuted(!on) }
            .onDisappear {
                // Lent to full screen, it plays on there. Already on another
                // channel's preview, it is that preview's to stop.
                guard !controller.lentToFullScreen, controller.previewChannelID == channelID else { return }
                controller.stop()
            }
    }

    private func open() {
        // Back from full screen, where it played on: nothing to open, but
        // its sound is on, as it was there.
        if controller.isOpen, controller.previewChannelID == channelID {
            // Written only if it differs: VLC on Apple TV restarts its sound
            // for every mute written.
            if controller.isMuted == audible { controller.setMuted(!audible) }
            return
        }
        controller.previewChannelID = channelID
        controller.start(urls: urls, muted: !audible)
        TVPreviewHandoff.previewing(channelID, in: controller)
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
            .font(.inter(12, .bold)).tracking(1.2)
            .foregroundStyle(GuidePalette.secondary)
            .padding(.horizontal, 7).frame(height: 22)
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
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool
    let focus: FocusState<String?>.Binding
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GuideSidebarHeading(title: "BROWSE")
            GuideSidebarButton(title: "All channels", symbol: "square.grid.2x2", selected: selectedCategoryID == nil && !favoritesOnly, focus: focus, focusID: "all") {
                selectedCategoryID = nil; favoritesOnly = false
            }
            GuideSidebarButton(title: "Favorites", symbol: "star", selected: favoritesOnly, focus: focus, focusID: "favorites") {
                selectedCategoryID = nil; favoritesOnly = true
            }
            GuideSidebarHeading(title: "CATEGORIES").padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.categories) { category in
                        GuideSidebarButton(title: category.categoryName, symbol: "rectangle.grid.1x2", selected: selectedCategoryID == category.id && !favoritesOnly, focus: focus, focusID: "category-" + category.id) {
                            selectedCategoryID = category.id; favoritesOnly = false
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

/// A sidebar row. The chosen one is white with a bar at its edge; the one the
/// remote is on wears the focus layer, so the two can never be confused.
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
        .background(selected ? GuidePalette.surface : Color.clear, in: shape)
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(GuidePalette.text).frame(width: 3, height: 22)
            }
        }
        .lineupFocusLayer(isFocused, in: shape)
        .contentShape(Rectangle()).focusable().focused(focus, equals: focusID).focusEffectDisabled().tvSelectAction(action)
        .animation(.easeOut(duration: 0.16), value: isFocused)
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
            .lineupFocusLayer(isFocused, in: shape)
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
                Text("NOW").font(.inter(12, .heavy)).tracking(0.6)
                    .foregroundStyle(GuidePalette.secondary)
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(17, .semibold))
                    .foregroundStyle(GuidePalette.text)
            }
            .lineLimit(1)
            .frame(width: layout.channelWidth)
            ForEach(0..<guideVisibleSlotCount, id: \.self) { step in
                HStack(spacing: 10) {
                    Rectangle().fill(GuidePalette.secondary.opacity(0.5)).frame(width: 1, height: 14)
                    Text(anchor.addingTimeInterval(Double(step) * 1800)
                        .formatted(date: .omitted, time: .shortened))
                        .font(.interDigits(16, .semibold))
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
                .font(.inter(12, .heavy)).tracking(0.8)
                .foregroundStyle(GuidePalette.channelText)
                .frame(width: channelWidth, alignment: .leading)
            HStack(spacing: 8) {
                GuideLiveDot(size: 7)
                Text("NOW")
                    .font(.inter(12, .heavy)).tracking(0.8)
                    .foregroundStyle(GuidePalette.channelText)
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(16, .semibold))
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
    private var target: GuideGridFocus?
    private var sentAt: TimeInterval = 0

    func heading(to focus: GuideGridFocus) {
        target = focus
        sentAt = ProcessInfo.processInfo.systemUptime
    }

    /// Where the last press sent focus, while it may still be on its way.
    /// After that, the focused cell itself is where a press starts.
    func headingTo() -> GuideGridFocus? {
        guard ProcessInfo.processInfo.systemUptime - sentAt < 0.45 else { return nil }
        return target
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

private struct GuideChannelRow: View {
    @Environment(\.guideLayout) private var layout
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let favoritesMode: Bool
    let now: Date
    let gridFocus: FocusState<GuideGridFocus?>.Binding
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
    private var programs: [CurrentProgram] { library.guidePrograms(for: stream) }

    private var visiblePrograms: [CurrentProgram] {
        let start = guideTimelineAnchor(now)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        return programs.filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
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
                    GuideProgramCell(program: nil, empty: "No guide information", quality: guideQuality(stream), now: now, showsTime: true, onPlay: onPlay, onFocus: {}, gridFocus: gridFocus, focusID: focusID, onMove: { onMoveFocus($0, focusID) })
                        .frame(width: layout.slotWidth - 6, alignment: .leading)
                } else {
                    ForEach(Array(visiblePrograms.enumerated()), id: \.offset) { _, program in
                        let width = guideProgramWidth(program, now: now, layout: layout)
                        let focusID = GuideGridFocus(streamID: stream.id, programStart: program.start)
                        GuideProgramCell(program: program, empty: "", quality: guideQuality(stream), now: now, showsTime: width >= 110, onPlay: onPlay, onFocus: { onFocusProgram(program) }, gridFocus: gridFocus, focusID: focusID, onMove: { onMoveFocus($0, focusID) })
                            .frame(width: width, alignment: .leading)
                            .offset(x: guideProgramX(program, now: now, layout: layout))
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
private struct GuideChannelListRow: View {
    @Environment(\.guideLayout) private var layout
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let program: CurrentProgram?
    let now: Date
    let quality: String?
    let favoritesMode: Bool
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    let onReorderFavorites: () -> Void
    let onStartOver: () -> Void
    let onCatchUp: () -> Void
    let onMoveFocus: (MoveCommandDirection, GuideGridFocus) -> Void
    let onFocus: () -> Void

    private var focusID: GuideGridFocus { GuideGridFocus(streamID: stream.id, programStart: nil) }
    private var isFocused: Bool { gridFocus.wrappedValue == focusID }
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
                    .font(.inter(25, .semibold))
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
                .font(.inter(14, .heavy)).tracking(0.5)
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
                .font(.inter(14, .semibold))
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
            .lineupFocusLayer(focused, in: Capsule())
            .contentShape(Capsule())
            .focusable().focused($focused).focusEffectDisabled()
            .tvSelectAction(action)
            .focusLift(focused, scale: LineupStyle.controlLift)
    }
}

private func guideProgramX(_ program: CurrentProgram, now: Date, layout: GuideLayout) -> CGFloat {
    let anchor = guideTimelineAnchor(now)
    let visibleStart = max(program.start, anchor)
    return max(0, CGFloat(visibleStart.timeIntervalSince(anchor) / 1800) * layout.slotWidth)
}

private func guideProgramWidth(_ program: CurrentProgram, now: Date, layout: GuideLayout) -> CGFloat {
    let anchor = guideTimelineAnchor(now)
    let windowEnd = anchor.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
    let visibleStart = max(program.start, anchor)
    let visibleEnd = min(program.end, windowEnd)
    let durationWidth = CGFloat(max(0, visibleEnd.timeIntervalSince(visibleStart)) / 1800) * layout.slotWidth
    return max(1, durationWidth - 6)
}

/// A programme block on its channel's own colour. Elapsed time keeps its
/// translucent fill; remote focus adds an edge without washing out the tint.
private struct GuideProgramCell: View {
    @Environment(\.guideLayout) private var layout
    let program: CurrentProgram?
    let empty: String
    let quality: String?
    let now: Date
    let showsTime: Bool
    let onPlay: () -> Void
    let onFocus: () -> Void
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let focusID: GuideGridFocus
    let onMove: (MoveCommandDirection) -> Void
    private var isFocused: Bool { gridFocus.wrappedValue == focusID }

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
                        .font(.inter(20, .semibold))
                        .foregroundStyle(GuidePalette.rowText)
                        .lineLimit(1)
                    if program.isNew == true { GuideTinyBadge(title: "NEW") }
                }
                if showsTime || isOnNow {
                    HStack(spacing: 8) {
                        if isOnNow {
                            GuideLiveDot(size: 8)
                            Text("LIVE")
                                .font(.inter(14, .semibold)).tracking(1.2)
                                .foregroundStyle(LineupStyle.liveStatus)
                        }
                        if showsTime {
                            Text(guideTimeRange(program))
                                .font(.interDigits(15, .medium))
                                .foregroundStyle(GuidePalette.secondary)
                                .lineLimit(1)
                            if let quality { GuideTinyBadge(title: quality) }
                        }
                    }
                }
            } else {
                Text(empty).font(.inter(18)).foregroundStyle(GuidePalette.channelText)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.rowHeight - 8, alignment: .topLeading)
        .background {
            ZStack(alignment: .leading) {
                if let program, isOnNow {
                    GeometryReader { geometry in
                        let played = GuideProgress.playedWidth(
                            start: program.start, end: program.end, now: now,
                            visibleStart: guideTimelineAnchor(now),
                            pointsPerSecond: Double(layout.slotWidth) / 1800,
                            cellWidth: Double(geometry.size.width))
                        // A low-contrast wash, not a second progress bar; its
                        // edge still ends where the timeline says now is.
                        Rectangle()
                            .fill(GuidePalette.rowText.opacity(0.13))
                            .frame(width: CGFloat(played), height: geometry.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }
            .clipShape(shape)
        }
        .overlay {
            if isFocused {
                shape.strokeBorder(LineupStyle.focusEdge, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .contentShape(Rectangle()).focusable().focused(gridFocus, equals: focusID).focusEffectDisabled().tvSelectAction(onPlay)
        .onMoveCommand(perform: onMove)
        .accessibilityValue(isOnNow ? "On now" : "")
        // Keep the focused block in timeline coordinates so its fill stays aligned.
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
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
