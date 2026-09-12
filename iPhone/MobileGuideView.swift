import SwiftUI
import UIKit

struct MobileGuideView: View {
    @EnvironmentObject private var library: SportsLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    @State private var category: String?
    @State private var favorites = false
    @State private var window = MobileGuideWindow(now: .now)
    @State private var horizontalOffset: CGFloat = 0
    @State private var resetPosition = UUID()
    @State private var playback = MobilePlaybackController()
    @State private var selectedStream: XtreamStream?
    @State private var expanded = false
    @State private var reorderingFavorites = false
    @ScaledMetric(relativeTo: .caption) private var rowHeight = 68.0
    var game: SportsGame? = nil
    var isActive = true
    var onFullscreenChange: (Bool) -> Void = { _ in }
    let onPlay: (XtreamStream) -> Void
    private let logoWidth: CGFloat = 80
    private var cardHeight: CGFloat { rowHeight - 6 }

    private var channels: [XtreamStream] {
        library.guideStreams(categoryID: category, favoritesOnly: favorites, query: query)
    }
    private var title: String {
        if game != nil { return "Choose a channel" }
        if favorites { return "Favorites" }
        return library.categories.first { $0.id == category }?.categoryName ?? "Guide"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                let showsMetadata = viewport.size.height > 400
                let metadataHeight: CGFloat = showsMetadata ? 106 : 0
                let videoHeight = min(viewport.size.width * 9 / 16, max(80, viewport.size.height * 0.52 - metadataHeight))
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        if selectedStream != nil {
                            Color.clear.frame(height: videoHeight + metadataHeight)
                        }
                        if let game {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(game.awayTeam) vs. \(game.homeTeam)").font(.subheadline.bold())
                                Text("Choose a channel · \(game.broadcast.isEmpty ? "Network unavailable" : game.broadcast)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                        if library.isLoading || library.isGuideLoading {
                            ProgressView("Updating guide…").font(.caption).padding(8)
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
                                videoHeight: expanded ? viewport.size.height : videoHeight,
                                onClose: closePlayer, onExpand: { expanded.toggle() },
                                onRetry: { playback.start(urls: library.playbackURLs(for: stream)) })
                                .frame(height: expanded ? viewport.size.height : videoHeight + metadataHeight, alignment: .top)
                                .background(LineupStyle.background)
                        }
                        .id(ObjectIdentifier(playback))
                        .modifier(MobileDismissGesture(enabled: expanded, onDismiss: closePlayer))
                    }
                }
            }
            .ignoresSafeArea(expanded ? .all : [], edges: .all)
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
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(LineupStyle.background)
                }
            }
            .toolbar {
                if game != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Now", systemImage: "clock.arrow.circlepath") { returnToNow() }
                    Menu {
                        Toggle("Favorites only", isOn: $favorites)
                        Picker("Category", selection: $category) {
                            Text("All channels").tag(nil as String?)
                            ForEach(library.categories) { Text($0.categoryName).tag(Optional($0.id)) }
                        }
                        Button("Refresh guide", systemImage: "arrow.clockwise") {
                            Task { await library.reload() }
                        }.disabled(library.channelsAreSyncing)
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("Guide filters")
                    Button {
                        if showsSearch { closeSearch() }
                        else { showsSearch = true }
                    } label: {
                        Image(systemName: showsSearch ? "xmark" : "magnifyingglass")
                    }
                    .accessibilityLabel(showsSearch ? "Close search" : "Search channels")
                    .accessibilityValue(showsSearch ? "Expanded" : "Collapsed")
                }
            }
            .toolbar(expanded ? .hidden : .visible, for: .navigationBar)
            .toolbar(expanded ? .hidden : .visible, for: .tabBar)
            .statusBarHidden(expanded)
            .persistentSystemOverlays(expanded ? .hidden : .automatic)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { returnToNow() }
                if selectedStream != nil {
                    if phase == .active { playback.resume() } else { playback.suspend() }
                }
            }
            .onChange(of: expanded) { _, value in
                if value { searchFocused = false }
                onFullscreenChange(value)
            }
            .onChange(of: isActive) { _, active in
                if !active { searchFocused = false; closePlayer() }
                else { returnToNow() }
            }
            .onAppear { returnToNow() }
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
        playback.start(urls: library.playbackURLs(for: stream))
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
                    .frame(height: max(0, viewport.size.height - 40))
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable { await library.reload() }
                }
                .frame(width: logoWidth + window.width, height: viewport.size.height, alignment: .topLeading)
                // This moment, drawn down the grid. Each card already shades
                // itself up to now, which says how far one programme has run
                // but never where the hour has got to. The line rides with the
                // timeline as it scrolls, because that is what it marks; the
                // channel column is drawn above it and covers it as it passes.
                .overlay(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        Circle().fill(LineupStyle.highlight).frame(width: 6, height: 6)
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [LineupStyle.highlight.opacity(0.9),
                                         LineupStyle.highlight.opacity(0.14)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(width: 1.5)
                    }
                    .frame(width: 6)
                    .padding(.top, 34)
                    .offset(x: logoWidth + window.x(now) - 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .background(MobileGuideScrollConfiguration(horizontal: true))
                .background {
                    GeometryReader { position in
                        Color.clear.preference(key: GuideHorizontalPosition.self,
                            value: position.frame(in: .named("guideHorizontal")).minX)
                    }
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
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
                Text("NOW").font(.system(size: 8, weight: .bold)).tracking(1)
                Text(now, format: .dateTime.hour().minute())
                    .font(.caption2.weight(.semibold)).monospacedDigit()
            }
                .frame(width: logoWidth, height: 40)
                .background(LineupStyle.background)
                .offset(x: horizontalOffset).zIndex(2)
            ZStack(alignment: .topLeading) {
                ForEach(window.ticks, id: \.self) { date in
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.leading, 7).frame(width: MobileGuideWindow.pointsPerSecond * 1800, height: 32, alignment: .leading)
                        .offset(x: window.x(date))
                }
            }.frame(width: window.width, height: 40, alignment: .topLeading)
        }
        .background(LineupStyle.background)
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
    }

    private func channelTile(_ stream: XtreamStream) -> some View {
        Button { selectChannel(stream) } label: {
            ZStack(alignment: .center) {
                AsyncImage(url: stream.streamIcon.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                            .frame(width: logoWidth - 16, height: min(42, cardHeight - 12), alignment: .center)
                    } else {
                        Text(stream.name).font(.caption2.weight(.semibold)).lineLimit(3)
                            .multilineTextAlignment(.center).padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: logoWidth - 8, height: cardHeight)
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
        .accessibilityLabel("Watch \(stream.name) live\(library.isFavorite(stream) ? ", favorite" : "")")
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
                        RoundedRectangle(cornerRadius: 8)
                            .fill(live ? LineupStyle.selected : LineupStyle.surface)
                        if program != nil {
                            // Played, in the text tint rather than the accent.
                            // A programme that began an hour ago is mostly
                            // elapsed, so an accent wash here is not a detail on
                            // a card -- it is a film over the entire guide.
                            Rectangle().fill(LineupStyle.lightPurple.opacity(0.07))
                                .frame(width: min(width, max(0, window.x(now) - cellX)))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(program?.title ?? "No listing")
                                .font(.caption.weight(program == nil ? .regular : .semibold)).lineLimit(2)
                                .foregroundStyle(LineupStyle.lightPurple.opacity(program == nil ? 0.5 : 1))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let program {
                                HStack(spacing: 5) {
                                    if live {
                                        Circle().fill(LineupStyle.highlight)
                                            .frame(width: 4, height: 4)
                                            .accessibilityHidden(true)
                                        Text("LIVE")
                                    } else {
                                        Text(program.start, format: .dateTime.hour().minute())
                                    }
                                    if program.isNew == true { Text("NEW") }
                                }
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                                .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(width: max(1, min(width - textInset, viewportWidth)), alignment: .leading)
                        .offset(x: textInset)
                    }
                    .frame(width: width, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(LineupStyle.lightPurple.opacity(live ? 0.15 : 0.04), lineWidth: 0.5)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
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
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.isDirectionalLockEnabled = true
        // Elastic horizontal overscroll would move the ruler beneath frozen logos.
        // Keep vertical elasticity for natural scrolling and pull-to-refresh.
        if horizontal { scroll.bounces = false }
    }
}
