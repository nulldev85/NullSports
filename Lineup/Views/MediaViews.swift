import SwiftUI

struct MediaServersView: View {
    @EnvironmentObject private var media: MediaLibrary
    @State private var addingServer = false

    var body: some View {
        NavigationStack {
            Group {
            #if os(tvOS)
            TVMediaServersHome(addingServer: $addingServer)
            #else
            Group {
                if media.activeProfile == nil {
                    ContentUnavailableView {
                        Label("Connect a Media Server", systemImage: "play.square.stack")
                    } description: {
                        Text("Browse your Jellyfin library or connect Nullfin for addon-powered catalogs and streams.")
                    } actions: {
                        Button("Add Media Server", systemImage: "plus") { addingServer = true }
                    }
                } else if media.roots.isEmpty && media.isLoading {
                    ProgressView("Loading libraries…")
                } else {
                    MediaCatalogsScreen(catalogs: media.catalogs)
                }
            }
            .background(LineupStyle.background.ignoresSafeArea())
            .navigationTitle("Media Servers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus") { addingServer = true }
                }
            }
            #endif
            }
            .sheet(isPresented: $addingServer) {
                MediaServerSetupView()
                    .environmentObject(media)
                    .preferredColorScheme(.dark)
            }
            .task {
                if media.activeProfile != nil && media.roots.isEmpty { await media.reload() }
            }
            .alert("Media Server", isPresented: Binding(
                get: { media.errorMessage != nil },
                set: { if !$0 { media.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(media.errorMessage ?? "Unknown error") }
        }
    }
}

#if os(tvOS)
private struct TVMediaServersHome: View {
    @EnvironmentObject private var media: MediaLibrary
    @Binding var addingServer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MEDIA SERVERS")
                        .font(.system(size: 13, weight: .bold)).tracking(2.2)
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    Text(media.activeProfile?.name ?? "Your library")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(LineupStyle.lightPurple)
                }
                Spacer()
                if let profile = media.activeProfile {
                    Label(profile.username, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LineupStyle.lightPurple.opacity(0.72))
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(LineupStyle.surface, in: Capsule())
                }
                Button { Task { await media.reload() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 42, height: 42)
                }
                .buttonStyle(TVMediaHeaderButtonStyle()).focusEffectDisabled().disabled(media.isLoading || media.activeProfile == nil)
                Button { addingServer = true } label: {
                    Label("Add Server", systemImage: "plus").padding(.horizontal, 4).frame(height: 42)
                }
                .buttonStyle(TVMediaHeaderButtonStyle()).focusEffectDisabled()
            }
            .padding(.horizontal, 54).padding(.top, 18)

            if media.activeProfile == nil {
                TVMediaEmptyState { addingServer = true }
            } else if media.roots.isEmpty && media.isLoading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Loading your libraries…").font(.headline)
                }
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if media.roots.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.exclamationmark").font(.system(size: 42, weight: .light))
                    Text("No libraries found").font(.title2.weight(.semibold))
                    Text("Refresh the server, or confirm this account can access a library.")
                        .font(.callout).opacity(0.68)
                }
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaCatalogsScreen(catalogs: media.catalogs)
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
    let add: () -> Void
    var body: some View {
        HStack(spacing: 34) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(LineupStyle.surface)
                Image(systemName: "play.square.stack.fill")
                    .font(.system(size: 72, weight: .light)).foregroundStyle(LineupStyle.lightPurple)
            }
            .frame(width: 210, height: 150)
            VStack(alignment: .leading, spacing: 12) {
                Text("Bring your media to the big screen.")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text("Connect Jellyfin or Nullfin to browse libraries, addon catalogs, and streams.")
                    .font(.system(size: 18)).opacity(0.68).frame(maxWidth: 590, alignment: .leading)
                Button("Connect a Server", systemImage: "plus", action: add)
                    .lineupButtonStyle().padding(.top, 6)
            }
            .foregroundStyle(LineupStyle.lightPurple)
        }
        .padding(42)
        .background(LineupStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(LineupStyle.line, lineWidth: 1))
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LineupStyle.lightPurple)
                .padding(.horizontal, 14).frame(minHeight: 42)
                .background(focused ? LineupStyle.focused : LineupStyle.surface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(LineupStyle.line, lineWidth: 1))
                .scaleEffect(focused ? 1.055 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: focused)
        }
    }
}
#endif

private struct MediaCatalogsScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let catalogs: [MediaCatalog]
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var searching = false
    @State private var searchError: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var addShelfFocused: Bool
    // tvOS pushes by hand because its cards are not NavigationLinks any more.
    @State private var pushed: MediaItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").opacity(0.58)
                    TextField("Search movies, shows, and addon catalogs", text: $query).textFieldStyle(.plain)
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
                Menu {
                    if media.availableShelves.isEmpty {
                        Button("All available shelves are visible") { }.disabled(true)
                    } else {
                        ForEach(media.availableShelves) { root in
                            Button(root.name, systemImage: "plus") { Task { await media.addShelf(root) } }
                        }
                    }
                } label: {
                    Label("Add Shelf", systemImage: "plus.rectangle.on.rectangle")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 16).frame(height: searchHeight)
                        .modifier(MediaChromeSurface(focused: addShelfFocused, radius: 13))
                }
                .focused($addShelfFocused)
                .focusEffectDisabled()
            }
            .padding(.horizontal, horizontalPadding).padding(.bottom, 18)

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if searching && results.isEmpty {
                    ProgressView("Searching connected addons…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let searchError {
                    ContentUnavailableView("Search Unavailable", systemImage: "exclamationmark.triangle", description: Text(searchError))
                } else if results.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                        description: Text("No connected catalog or metadata addon returned a match."))
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
                                    TVSelectable(action: { media.removeShelf(catalog) }) {
                                        MediaChromeLabel {
                                            Image(systemName: "minus.circle")
                                                .accessibilityLabel("Remove \(catalog.title) shelf")
                                        }
                                    }
                                    #else
                                    Button { media.removeShelf(catalog) } label: {
                                        MediaChromeLabel {
                                            Image(systemName: "minus.circle")
                                                .accessibilityLabel("Remove \(catalog.title) shelf")
                                        }
                                    }.lineupFlatButton()
                                    #endif
                                    #if os(tvOS)
                                    TVSelectable(action: { pushed = catalog.root }) {
                                        MediaChromeLabel {
                                            Label("See All", systemImage: "chevron.right")
                                                .font(.system(size: 14, weight: .semibold))
                                        }
                                    }
                                    #else
                                    NavigationLink(value: catalog.root) {
                                        MediaChromeLabel {
                                            Label("See All", systemImage: "chevron.right")
                                                .font(.system(size: 14, weight: .semibold))
                                        }
                                    }.lineupFlatButton()
                                    #endif
                                }
                                .padding(.horizontal, horizontalPadding)
                                if catalog.items.isEmpty {
                                    Text("No titles in this catalog.").font(.callout)
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
                                                    if item.isFolder {
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
        .task(id: query) {
            let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { results = []; searching = false; searchError = nil; return }
            searching = true
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
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
        .system(size: 24, weight: .semibold, design: .rounded)
        #else
        .title3.weight(.bold)
        #endif
    }
    private var searchFont: Font {
        #if os(tvOS)
        .system(size: 19, weight: .medium)
        #else
        .body
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(items) { item in
                    if item.isFolder {
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

/// A series opens to its own page; anything else is still a grid of what is
/// inside it. Both destinations are registered under one item type, so the
/// choice has to be made here rather than at the link.
private struct MediaBrowseDestination: View {
    let item: MediaItem

    var body: some View {
        if item.isSeries {
            MediaShowScreen(series: item)
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
            if loading { ProgressView("Loading \(folder.name)…") }
            else if let error {
                ContentUnavailableView("Couldn’t Load Library", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if items.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "film.stack",
                    description: Text("This library did not return any playable items."))
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

/// The page a series opens to: its art, what to play next, and the season the
/// viewer is on with every episode in it. A season used to be one more grid of
/// unlabelled cards, which said nothing about the episode being picked.
private struct MediaShowScreen: View {
    @EnvironmentObject private var media: MediaLibrary
    let series: MediaItem

    @State private var detail: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var selectedSeason: MediaItem?
    @State private var episodes: [MediaItem] = []
    @State private var nextUp: MediaItem?
    @State private var metrics: [MediaMetric] = []
    @State private var favorite = false
    @State private var expandedOverview = false
    @State private var loading = true
    @State private var error: String?
    @State private var chosen: MediaItem?
    @FocusState private var seasonFocused: Bool

    private var show: MediaItem { detail ?? series }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                VStack(alignment: .leading, spacing: 16) {
                    if !show.hasLogo { Text(show.name).font(titleFont) }
                    metaLine
                    actions
                    overview
                    ratings
                }
                .padding(.horizontal, horizontalPadding)
                episodesSection
            }
            .padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupStyle.background.ignoresSafeArea())
        .foregroundStyle(LineupStyle.lightPurple)
        .modifier(FullBleedHeader())
        .task(id: series.id) { await load() }
        .sheet(item: $chosen) { episode in MediaSourcePicker(item: episode) }
    }

    // MARK: - Header

    private var hero: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(heroRatio, contentMode: .fit)
            .overlay {
                ZStack {
                    LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    AsyncImage(url: heroURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                }
            }
            .clipped()
            // The art has to end somewhere, and a hard edge across the screen
            // reads as a seam. It fades into the page instead.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, LineupStyle.background],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
            }
            .overlay(alignment: .bottom) {
                if show.hasLogo {
                    AsyncImage(url: media.logoURL(for: show)) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                    }
                    .frame(height: logoHeight)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 6)
                }
            }
    }

    @ViewBuilder
    private var metaLine: some View {
        if !metaParts.isEmpty {
            Text(metaParts.joined(separator: "  \u{00B7}  "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
        }
    }

    private var metaParts: [String] {
        [show.productionYear.map(String.init),
         show.genres?.prefix(2).joined(separator: ", "),
         show.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    // MARK: - Actions

    /// What the play button starts: the server's own next-up answer, else the
    /// first unwatched episode on screen, else the season from the top.
    private var playTarget: MediaItem? {
        nextUp ?? episodes.first { !$0.isPlayed } ?? episodes.first
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { chosen = playTarget } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play").fontWeight(.bold)
                    if let code = playTarget?.episodeCode {
                        Text(code).foregroundStyle(LineupStyle.background.opacity(0.5))
                    }
                }
                .font(.system(size: 17))
                .frame(maxWidth: .infinity).frame(height: buttonHeight)
                .modifier(MediaChromeFocus(prominent: true))
            }
            .lineupFlatButton()
            .disabled(playTarget == nil)
            .opacity(playTarget == nil ? 0.45 : 1)

            iconButton(favorite ? "bookmark.fill" : "bookmark") {
                favorite.toggle()
                Task { await media.setFavorite(favorite, for: show) }
            }
            iconButton("shuffle") { chosen = episodes.randomElement() ?? playTarget }
                .disabled(episodes.isEmpty)
        }
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        let label = Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            .frame(width: buttonHeight + 8, height: buttonHeight)
            .modifier(MediaChromeFocus())
        #if os(tvOS)
        TVSelectable(action: action) { label }
        #else
        Button(action: action) { label }.lineupFlatButton()
        #endif
    }

    @ViewBuilder
    private var overview: some View {
        if let text = show.overview, !text.isEmpty {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.76))
                .lineLimit(expandedOverview ? nil : 3)
                .multilineTextAlignment(.leading)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { expandedOverview.toggle() }
                }
        }
    }

    private struct Rating: Identifiable {
        let id: String
        let source: String
        let value: String
    }

    // Only what the server actually reports. An empty row beats an invented one.
    //
    // A Nullfin server keeps a score per metrics addon, and naming the source
    // beside each one is the whole point of showing them. Where it has none --
    // any Jellyfin server, or an item no addon has scored -- the item's own two
    // ratings stand in, and the community score is named too: Nullfin fills it
    // from the metadata addon's IMDb rating, and an unlabelled star said
    // nothing about where the number came from.
    private var ratingValues: [Rating] {
        guard metrics.isEmpty else {
            return metrics.map {
                Rating(id: $0.source, source: $0.displayName, value: $0.formattedValue)
            }
        }
        var values: [Rating] = []
        if let community = show.communityRating, community > 0 {
            values.append(Rating(id: "community", source: "IMDb",
                value: String(format: "%.1f", community)))
        }
        if let critic = show.criticRating, critic > 0 {
            values.append(Rating(id: "critic", source: "Critics",
                value: "\(Int(critic.rounded()))%"))
        }
        return values
    }

    @ViewBuilder
    private var ratings: some View {
        if !ratingValues.isEmpty {
            // Six sources do not fit across a phone, so they wrap rather than
            // squeeze, the same way the stream badges do.
            BadgeFlow(spacing: 16) {
                ForEach(ratingValues) { rating in
                    HStack(spacing: 6) {
                        Text(rating.source)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
                        Text(rating.value)
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    .fixedSize()
                }
            }
            .foregroundStyle(LineupStyle.lightPurple.opacity(0.82))
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            seasonHeading.padding(.horizontal, horizontalPadding)
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if let error {
                Text(error).font(.footnote)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    .padding(.horizontal, horizontalPadding)
            } else if episodes.isEmpty {
                Text("No episodes here yet.").font(.footnote)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    .padding(.horizontal, horizontalPadding)
            } else {
                LazyVGrid(columns: episodeColumns, spacing: 22) {
                    ForEach(episodes) { episode in
                        Button { chosen = episode } label: { MediaEpisodeCard(episode: episode) }
                            .lineupFlatButton()
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
        }
    }

    @ViewBuilder
    private var seasonHeading: some View {
        if seasons.count > 1 {
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
        } else {
            Text(selectedSeason?.name ?? "Episodes").font(sectionTitleFont)
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        error = nil
        let loaded = try? await media.details(of: series)
        detail = loaded ?? series
        favorite = (loaded ?? series).isFavorite
        metrics = await media.metrics(for: series)
        do {
            let children = try await media.numberedChildren(of: series)
            let seasonList = children.filter { $0.type == "Season" }
            guard !seasonList.isEmpty else {
                // Some addon catalogs hang episodes straight off the series.
                seasons = []
                selectedSeason = nil
                episodes = children.filter(\.isPlayable)
                loading = false
                return
            }
            seasons = seasonList
            let up = await media.nextUp(in: series)
            nextUp = up
            await loadSeason(seasonList.first { $0.indexNumber == up?.parentIndexNumber } ?? seasonList[0])
        } catch {
            self.error = error.localizedDescription
            loading = false
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
        media.backdropURL(for: show) ?? media.imageURL(for: show, width: 1280)
        #else
        media.imageURL(for: show, width: 900)
        #endif
    }
    private var heroRatio: CGFloat {
        #if os(tvOS)
        // A full-width 16:9 hero is exactly one 16:9 screen, so the title,
        // actions and episodes all landed below the fold and the page looked
        // like nothing but artwork had loaded. Half a screen leaves the rest
        // of the page on screen with it.
        32 / 9
        #else
        2 / 3
        #endif
    }
    private var logoHeight: CGFloat {
        #if os(tvOS)
        110
        #else
        76
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
        58
        #else
        50
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .system(size: 40, weight: .bold, design: .rounded)
        #else
        .title.weight(.bold)
        #endif
    }
    private var sectionTitleFont: Font {
        #if os(tvOS)
        .system(size: 24, weight: .semibold, design: .rounded)
        #else
        .title3.weight(.bold)
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
                        AsyncImage(url: media.imageURL(for: episode, width: 640)) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { Image(systemName: "film.fill").font(.largeTitle) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12)
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
                Text(label).font(.caption.weight(.semibold))
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
            }
            Text(episode.name).font(.subheadline.weight(.bold)).lineLimit(2)
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview).font(.caption).lineLimit(3)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
            }
            if !footer.isEmpty {
                Text(footer).font(.caption2)
                    .foregroundStyle(LineupStyle.lightPurple.opacity(0.45))
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(LineupStyle.lightPurple)
        .focusLift(focused, scale: 1.03)
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
            .sheet(isPresented: $choosingSource) {
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

    // Addons in the order the server ranked their best result, so the chip row
    // reads the same way the list below it does.
    private var providers: [String] {
        var seen: Set<String> = []
        return sources.map(\.provider).filter { seen.insert($0).inserted }
    }

    private var visibleSources: [MediaPlaybackSource] {
        guard let providerFilter else { return sources }
        return sources.filter { $0.provider == providerFilter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Finding the best streams…").font(.headline)
                        Text("Connected addons are ranking results for \(item.name).")
                            .font(.subheadline).foregroundStyle(LineupStyle.lightPurple.opacity(0.62))
                    }
                } else if let error {
                    ContentUnavailableView("Streams Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if sources.isEmpty {
                    ContentUnavailableView("No Streams Found", systemImage: "play.slash",
                        description: Text("None of the connected streaming addons returned a playable result."))
                } else {
                    VStack(spacing: 0) {
                        // Results arrive interleaved from every connected addon, and
                        // a viewer who trusts one of them wants to see only its rows.
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
                        }
                        ScrollView {
                            LazyVStack(spacing: rowSpacing) {
                                ForEach(visibleSources) { source in
                                    Button { selectedSource = source } label: {
                                        MediaSourceRow(source: source)
                                    }
                                    .lineupFlatButton()
                                }
                            }
                            .padding(.horizontal, horizontalPadding).padding(.vertical, 20)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LineupStyle.background.ignoresSafeArea())
            .foregroundStyle(LineupStyle.lightPurple)
            .navigationTitle(item.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: dismiss.callAsFunction) }
            }
        }
        .task(id: item.id) {
            loading = true
            providerFilter = nil
            do { sources = try await media.playbackSources(for: item); error = nil }
            catch { self.error = error.localizedDescription }
            loading = false
        }
        .fullScreenCover(item: $selectedSource) { source in
            if let url = media.playbackURL(for: item, source: source) {
                #if os(tvOS)
                PlayerView(urls: [url], title: item.name, isLive: false)
                #else
                MobilePlayerView(name: item.name, urls: [url])
                #endif
            } else { ContentUnavailableView("Playback Unavailable", systemImage: "play.slash") }
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
        16
        #else
        10
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

/// The chip draws its own selection and its own focus, so a remote moving across
/// the row reads the same as a finger tapping one.
/// tvOS lights whatever has focus by drawing a white plate behind it, sized to
/// the whole control. On a poster that plate covers the title under the art as
/// well, and white belongs to no part of this palette. Every focusable thing in
/// these screens turns that effect off and draws its own focus instead: the
/// cards and rows already did, and this is what the chrome around them uses.
private struct MediaChromeSurface: ViewModifier {
    var focused = false
    var prominent = false
    /// A field the viewer types into. It marks focus with its edge only: filling
    /// it would put dark text on a light field mid-sentence, which is the same
    /// jarring inversion this is all here to remove.
    var outline = false
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .foregroundStyle(filled ? LineupStyle.background : LineupStyle.lightPurple)
            .background(filled ? LineupStyle.lightPurple
                : (focused ? LineupStyle.focused : LineupStyle.surface),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .stroke(border, lineWidth: 1))
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
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
            .scaleEffect(focused ? 1.04 : 1)
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
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Text("\(count)").font(.caption2.weight(.bold)).monospacedDigit().opacity(0.55)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(active ? LineupStyle.background : LineupStyle.lightPurple)
        .background(active ? LineupStyle.lightPurple
            : (focused ? LineupStyle.focused : LineupStyle.surface), in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1))
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }

    // Constant: the chip shows whether it is active, not whether it is focused.
    private var border: Color { active ? .clear : LineupStyle.line }
}

private struct MediaSourceRow: View {
    @Environment(\.isFocused) private var focused
    let source: MediaPlaybackSource

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Resolution, ranking score and addon answer "is this worth reading?",
            // so they sit above the name rather than competing for its width.
            HStack(spacing: 8) {
                if let quality = source.quality {
                    Text(quality)
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(accent.opacity(0.2), in: Capsule())
                }
                // A bare "+70494" does not say what it measures, and it is the
                // number the whole list is ordered by, so it is named in full.
                if let score = source.score {
                    HStack(spacing: 4) {
                        Text("Ranking Score:").font(.caption2.weight(.semibold)).opacity(0.62)
                        Text(score >= 0 ? "+\(score)" : "\(score)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                    }
                    .fixedSize()
                }
                Spacer(minLength: 4)
                Text(source.provider).font(.caption.weight(.bold)).lineLimit(1)
                Image(systemName: "play.circle.fill").font(.title3).fixedSize()
            }
            Text(source.releaseName)
                .font(.subheadline.weight(.semibold)).lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !source.badges.isEmpty {
                BadgeFlow(spacing: 6) {
                    ForEach(source.badges, id: \.self) { badge($0) }
                }
            }
            if !source.facts.isEmpty {
                Text(source.facts.joined(separator: "  \u{00B7}  "))
                    .font(.caption2).monospacedDigit().lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(accent.opacity(0.6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? LineupStyle.focused : LineupStyle.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(LineupStyle.line, lineWidth: 1))
        .foregroundStyle(accent)
        .scaleEffect(focused ? 1.018 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
        .accessibilityElement(children: .combine)
    }

    // The row no longer inverts on focus, so every shade stays mixed from the
    // one readable colour.
    private var accent: Color { LineupStyle.lightPurple }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).lineLimit(1).fixedSize()
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
                        AsyncImage(url: media.imageURL(for: item)) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { Image(systemName: item.isFolder ? "rectangle.stack.fill" : "film.fill").font(.largeTitle) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cardRadius)
                    .stroke(LineupStyle.line, lineWidth: 1))
            // Two lines are held whether or not the title needs them, so the line
            // under it lands on the same baseline across a row.
            Text(item.name).font(titleFont).lineLimit(2, reservesSpace: true)
            HStack(spacing: 7) {
                Text(item.type.uppercased())
                if let year = item.productionYear { Text("· \(String(year))") }
                if let count = item.childCount { Text("· \(count)") }
            }
            .font(.caption2.weight(.medium)).foregroundStyle(LineupStyle.lightPurple.opacity(0.58))
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .focusLift(focused, scale: 1.035)
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
        .headline
        #else
        .subheadline.weight(.semibold)
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
                    // A password is not required. Jellyfin-compatible servers
                    // allow passwordless users, and some ship that way until an
                    // operator sets one -- refusing to try left those servers
                    // unreachable with the button simply dead.
                    .disabled(media.isLoading
                        || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Supports Jellyfin, Nullfin and other Jellyfin-compatible servers, whose libraries include the catalogs and streams from any addons configured on them. Leave the password blank for a user that has none. Access tokens are stored securely in this device’s Keychain.")
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
