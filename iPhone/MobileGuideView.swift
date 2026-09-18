import SwiftUI
import UIKit

struct MobileGuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    @State private var category: String?
    @State private var favorites = false
    @State private var recents = false
    @State private var window = MobileGuideWindow(now: .now)
    @State private var horizontalOffset: CGFloat = 0
    @State private var resetPosition = UUID()
    @State private var playback = MobilePlaybackController()
    @State private var selectedStream: XtreamStream?
    @State private var expanded = false
    @State private var reorderingFavorites = false
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

    private var channels: [XtreamStream] {
        let listed = library.guideStreams(categoryID: category, favoritesOnly: favorites,
                                          query: query, recentsOnly: recents)
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
        if favorites { return "Favorites" }
        if recents { return "Recent" }
        return library.categories.first { $0.id == category }?.categoryName ?? "Guide"
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
                        if library.isLoading || library.isGuideLoading {
                            ProgressView("Updating guide…").font(.inter(.caption)).padding(8)
                        }
                        if channels.isEmpty {
                            ContentUnavailableView("No channels", systemImage: "tv",
                                description: Text("Try another category or search, or refresh your guide."))
                        } else {
                            TimelineView(.periodic(from: .now, by: 5)) { clock in
                                guide(now: clock.date)
                                    .onChange(of: clock.date) { _, now in
                                        // Keep live in view while preserving deliberate future browsing.
                                        if horizontalOffset < 1 && window.isStale(at: now) {
                                            window = MobileGuideWindow(now: now)
                                        }
                                    }
                            }
                        }
                    }
                    .allowsHitTesting(!expanded)
                    .accessibilityHidden(expanded)
                    if let stream = selectedStream {
                        TimelineView(.periodic(from: .now, by: 5)) { clock in
                            MobileGuidePlayer(controller: playback, stream: stream,
                                program: library.guidePrograms(for: stream).first { $0.start <= clock.date && clock.date < $0.end },
                                expanded: expanded, showsMetadata: showsMetadata,
                                videoHeight: expanded ? fullHeight : videoHeight,
                                onClose: closePlayer, onExpand: { setExpanded(!expanded) },
                                onRetry: { playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id) })
                                .frame(height: expanded ? fullHeight : videoHeight + metadataHeight, alignment: .top)
                                .background(LineupStyle.background)
                        }
                        // The player is the one thing that reaches past the
                        // chrome, so it claims the whole screen itself rather
                        // than waiting for the guide around it to get out of the
                        // way first. Its position and size stay identical
                        // whether or not the bars have finished hiding.
                        .ignoresSafeArea(expanded ? .all : [], edges: .all)
                        .id(ObjectIdentifier(playback))
                        .modifier(MobileDismissGesture(enabled: expanded, onDismiss: closePlayer))
                    }
                }
            }
            .background(LineupStyle.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsSearch && !expanded {
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
                    .background(LineupStyle.raised, in: RoundedRectangle(cornerRadius: LineupStyle.compactRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: LineupStyle.compactRadius).stroke(LineupStyle.line, lineWidth: 1))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(LineupStyle.background)
                }
            }
            .toolbar {
                if game != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Return to Now", systemImage: "clock.arrow.circlepath") { returnToNow() }
                        Button(showsSearch ? "Close Search" : "Search Channels",
                               systemImage: showsSearch ? "xmark" : "magnifyingglass") {
                            if showsSearch { closeSearch() }
                            else { showsSearch = true }
                        }
                        Divider()
                        Toggle("Favorites only", isOn: Binding(
                            get: { favorites },
                            set: { favorites = $0; if $0 { recents = false } }))
                        Toggle("Recently watched", isOn: Binding(
                            get: { recents },
                            set: { recents = $0; if $0 { favorites = false } }))
                        .disabled(library.recentStreams.isEmpty)
                        Picker("Category", selection: $category) {
                            Text("All channels").tag(nil as String?)
                            ForEach(library.categories) { Text($0.categoryName).tag(Optional($0.id)) }
                        }
                        Divider()
                        Button("Refresh guide", systemImage: "arrow.clockwise") {
                            Task { await library.reload() }
                        }.disabled(library.channelsAreSyncing)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Guide options")
                }
            }
            .toolbar(expanded ? .hidden : .visible, for: .navigationBar)
            .toolbar(expanded ? .hidden : .visible, for: .tabBar)
            .statusBarHidden(expanded)
            .persistentSystemOverlays(expanded ? .hidden : .automatic)
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
            .onChange(of: expanded) { _, value in
                if value { searchFocused = false }
                onFullscreenChange(value)
            }
            .onChange(of: isActive) { _, active in
                // Leaving the Guide tab still tears the player down — except
                // while the PiP window is showing this stream, which the viewer
                // asked to keep watching.
                if !active {
                    searchFocused = false
                    if !playback.pictureInPictureActive { closePlayer() }
                } else { returnToNow() }
            }
            .onAppear {
                returnToNow()
                if let game { recommendedStreamID = library.verifiedStream(for: game)?.id }
            }
            .sheet(isPresented: $reorderingFavorites) {
                FavoritesOrderView()
                    .environmentObject(library)
                    .tint(LineupStyle.highlight)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private func selectChannel(_ stream: XtreamStream) {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        // The manual game picker still returns its selection to the Live screen.
        guard game == nil else { onPlay(stream); return }
        guard selectedStream?.id != stream.id else { return }
        // A new selection gets a new VLC session and surface. A stopped renderer
        // from an earlier tab visit must never become the next channel's output.
        playback.shutdown()
        playback = MobilePlaybackController()
        selectedStream = stream
        playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id)
    }

    /// Expanding moves the video, the guide behind it, the navigation bar, the
    /// tab bar and the status bar. Driving all of it from one animated change is
    /// what makes it read as a single motion instead of the video jumping first
    /// and the chrome catching up afterwards.
    private func setExpanded(_ value: Bool) {
        guard !reduceMotion else {
            expanded = value
            onFullscreenChange(value)
            return
        }
        withAnimation(.smooth(duration: 0.34)) {
            expanded = value
            onFullscreenChange(value)
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
                        .background(MobileGuideScrollConfiguration(horizontal: false))
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                    // The scrollers adjust no insets of their own, so the last
                    // channel has to be given room to clear the floating tab
                    // bar itself. Without this it sits underneath it, readable
                    // only by scrolling past the end.
                    .contentMargins(.bottom, viewport.safeAreaInsets.bottom, for: .scrollContent)
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
        Button { selectChannel(stream) } label: {
            ZStack(alignment: .center) {
                AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
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
                        .foregroundStyle(LineupStyle.background)
                        .padding(.bottom, 1)
                }
            }
            .overlay(alignment: .topLeading) {
                if library.isFavorite(stream) {
                    Image(systemName: "star.fill").font(.caption2)
                        .padding(4).background(LineupStyle.background.opacity(0.85), in: Circle())
                        .padding(3)
                }
            }
            .frame(width: logoWidth, height: rowHeight, alignment: .center)
            .contentShape(Rectangle())
            // The frozen column masks scrolling programs with the guide's base color.
            .background(LineupStyle.background)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isRecommended(stream) ? "Recommended. " : "")Watch \(stream.name) live\(library.isFavorite(stream) ? ", favorite" : "")")
        .contextMenu {
            if library.isFavorite(stream) {
                if favorites {
                    Button("Move up", systemImage: "arrow.up") { library.moveFavorite(stream, offset: -1) }
                        .disabled(!library.canMoveFavorite(stream, offset: -1))
                    Button("Move down", systemImage: "arrow.down") { library.moveFavorite(stream, offset: 1) }
                        .disabled(!library.canMoveFavorite(stream, offset: 1))
                }
                Button("Reorder favorites", systemImage: "arrow.up.arrow.down") { reorderingFavorites = true }
                Button("Remove favorite", systemImage: "star.slash", role: .destructive) {
                    library.removeFavorite(stream)
                }
            } else {
                Button("Add favorite", systemImage: "star") { library.addFavorite(stream) }
            }
        }
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
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(live ? LineupStyle.focused : LineupStyle.raised)
                        if program != nil {
                            // A quiet elapsed-state wash without tying progress
                            // to the theme accent.
                            Rectangle().fill(LineupStyle.text.opacity(0.10))
                                .frame(width: min(width, max(0, window.x(now) - cellX)))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(program?.title ?? "No listing")
                                .font(.inter(.caption, program == nil ? .regular : .semibold)).lineLimit(2)
                                .foregroundStyle(program == nil ? LineupStyle.secondary : LineupStyle.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let program {
                                HStack(spacing: 5) {
                                    if live {
                                        Circle().fill(LineupStyle.liveDot)
                                            .frame(width: 4, height: 4)
                                            .accessibilityHidden(true)
                                        Text("LIVE")
                                    } else {
                                        Text(program.start, format: .dateTime.hour().minute())
                                    }
                                    if program.isNew == true { Text("NEW") }
                                }
                                .font(.inter(9, .medium))
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                                .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(width: max(1, min(width - textInset, viewportWidth)), alignment: .leading)
                        .offset(x: textInset)
                    }
                    .frame(width: width, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(live ? LineupStyle.liveDot.opacity(0.34) : LineupStyle.line, lineWidth: live ? 1 : 0.5)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
                    ContentUnavailableView("No favorites", systemImage: "star",
                        description: Text("Touch and hold a channel in the guide to add it."))
                } else {
                    List {
                        ForEach(listed) { stream in
                            HStack(spacing: 12) {
                                AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    Image(systemName: "tv").foregroundStyle(.secondary)
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
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Navigation already positions this guide within the safe area. Its two nested
/// scrollers must not add that navigation inset again above the first channel.
struct MobileGuideScrollConfiguration: UIViewRepresentable {
    let horizontal: Bool
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            var ancestor = view?.superview
            while let candidate = ancestor {
                if let scroll = candidate as? UIScrollView {
                    Self.configure(scroll, horizontal: horizontal)
                    break
                }
                ancestor = candidate.superview
            }
        }
    }
    static func configure(_ scroll: UIScrollView, horizontal: Bool) {
        // Navigation already positions the guide inside the safe area, and
        // letting these scrollers adjust again put that inset in twice. The
        // cost is that they adjust for nothing else either, so the insets that
        // do matter -- the tab bar below, the island at the sides -- are
        // applied by the guide itself rather than left to the scroller.
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.isDirectionalLockEnabled = true
        // Elastic horizontal overscroll would move the ruler beneath frozen logos.
        // Keep vertical elasticity for natural scrolling and pull-to-refresh.
        if horizontal { scroll.bounces = false }
    }
}
