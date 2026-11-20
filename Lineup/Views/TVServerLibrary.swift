#if os(tvOS)
import SwiftUI

/// Which Library the tab shows, at the top of the Library: Lineup's own,
/// which brings every server together, or one server's own.
struct TVServerLibrarySwitcher: View {
    @Environment(MediaLibrary.self) private var media
    @AppStorage(MediaLibrary.serverLibraryKey) private var serverLibrary = ""

    var body: some View {
        let servers = media.serverLibraryProfiles
        if !servers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    TVServerLibraryChip(title: "Lineup", symbol: "square.stack.3d.up",
                                        chosen: !servers.contains { $0.id.uuidString == serverLibrary }) {
                        serverLibrary = ""
                    }
                    ForEach(servers) { server in
                        TVServerLibraryChip(title: server.name, logo: server.brand, brand: server.brand,
                                            chosen: server.id.uuidString == serverLibrary) {
                            serverLibrary = server.id.uuidString
                        }
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 14)
            }
            .scrollClipDisabled()
            .lineupFocusRegion()
        }
    }
}

/// A chip in one of the Library's rows of choices, drawn as the Sports
/// cards are: the app's dark card, and when chosen its server's colours laid
/// faintly across it -- brighter under the remote -- with a hairline edge.
/// Lineup's own chip takes a faint white in place of a server's colours.
struct TVServerLibraryChip: View {
    let title: String
    var symbol: String? = nil
    /// A server's logo, ahead of its name.
    var logo: MediaServerBrand? = nil
    var detail: String? = nil
    /// Whose colours it takes when chosen.
    var brand: MediaServerBrand? = nil
    let chosen: Bool
    let action: () -> Void

    var body: some View {
        TVSelectable(scale: LineupStyle.controlLift, fillRadius: 30, drawsFocusChrome: false, action: action) {
            TVServerLibraryChipFace(title: title, symbol: symbol, logo: logo, detail: detail,
                                    brand: brand, chosen: chosen)
        }
    }
}

private struct TVServerLibraryChipFace: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    let symbol: String?
    let logo: MediaServerBrand?
    let detail: String?
    let brand: MediaServerBrand?
    let chosen: Bool

    private var tints: [Color] { brand?.cardTints ?? [.white, .white] }

    var body: some View {
        let strength = brand == nil ? (focused ? 0.2 : 0.13) : (focused ? 0.34 : 0.22)
        HStack(spacing: 10) {
            if let logo { MediaServerLogo(brand: logo).frame(width: 30, height: 30) }
            else if let symbol { Image(systemName: symbol).font(.system(size: 22, weight: .bold)) }
            Text(title).font(.inter(24, chosen ? .bold : .semibold)).lineLimit(1)
            if let detail { Text(detail).font(.inter(19, .semibold)).opacity(0.6) }
        }
        .foregroundStyle(chosen || focused ? LineupStyle.text.opacity(0.92) : LineupPanelStyle.quiet)
        .padding(.horizontal, 26).frame(height: 60)
        .background {
            if chosen {
                Capsule().fill(LinearGradient(colors: tints.map { $0.opacity(strength) },
                                              startPoint: .leading, endPoint: .trailing))
            }
        }
        .background(focused && !chosen ? LineupPanelStyle.well : LineupPanelStyle.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// One server's own Library on the television: the same three pages as on
/// the phone, as rows of choices and cards the remote moves between.
struct TVServerLibraryScreen: View {
    @Environment(MediaLibrary.self) private var media
    let profile: MediaServerProfile

    var body: some View {
        if let model = media.serverLibraryModel(for: profile) {
            let silo = media.siloPagesModel(for: profile)
            TVServerLibraryContent(model: model, silo: silo)
                .id(profile.id)
                .task { await model.start() }
                .task { await silo?.refresh() }
        } else {
            VStack(spacing: 0) {
                TVServerLibrarySwitcher()
                Text("\(profile.name)'s own Library can't be shown right now.")
                    .font(.inter(24)).foregroundStyle(LineupPanelStyle.quiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct TVServerLibraryContent: View {
    @Environment(MediaLibrary.self) private var media
    @Bindable var model: ServerLibraryModel
    let silo: SiloPagesModel?
    @State private var seeingSilo: ServerLibraryRow?
    @State private var jumpTarget: String?
    @FocusState private var gridFocus: String?
    @State private var pushed: MediaItem?
    @State private var seeing: ServerLibraryRow?
    @State private var choosingLibrary = false
    @State private var choosingSort = false
    @State private var choosingFilter = false
    @State private var shuffling = false

    /// The server's own colours, from its logo.
    private var brand: MediaServerBrand { model.profile.brand }

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 290), spacing: 40, alignment: .top)]

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 34) {
                    TVServerLibrarySwitcher()
                    if let silo { siloPlaces(silo) }
                    if let silo, silo.place != .library {
                        TVSiloPage(model: silo, open: { pushed = $0 }, seeAll: { seeingSilo = $0 })
                    } else {
                        pages
                        switch model.tab {
                        case .recommended: recommended
                        case .library: library
                        case .collections: collections
                        }
                    }
                }
                .padding(.top, 10).padding(.bottom, 80)
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if (silo?.place ?? .library) == .library, model.tab == .library,
                   model.titlesPhase == .loaded, model.browse.jumpsByLetter, !model.letters.letters.isEmpty {
                    letters(scroll: scroll)
                }
            }
        }
        .scrollClipDisabled()
        .tint(LineupStyle.text)
        // Everything opened from here, and anything opened from that, is
        // played from this server alone.
        .navigationDestination(item: $pushed) { item in
            MediaBrowseDestination(item: item).environment(\.mediaStreamScope, model.profile.id)
        }
        .navigationDestination(item: $seeingSilo) { row in
            if let silo { TVSiloHomeRowScreen(model: silo, row: row) }
        }
        .navigationDestination(item: $seeing) { row in
            TVServerLibraryRowScreen(model: model, row: row).environment(\.mediaStreamScope, model.profile.id)
        }
        .navigationDestination(for: MediaItem.self) { item in
            MediaBrowseDestination(item: item).environment(\.mediaStreamScope, model.profile.id)
        }
        .environment(\.mediaStreamScope, model.profile.id)
        .tvChoices(model.profile.name, symbol: "rectangle.stack", isPresented: $choosingLibrary) {
            model.libraries.map { library in
                TVChoice(library.name, id: library.id, isSelected: library.id == model.library?.id) {
                    model.choose(library)
                }
            }
        }
        .tvChoices("Sort By", symbol: "arrow.up.arrow.down", isPresented: $choosingSort) {
            ServerLibrarySort.allCases.map { sort in
                let current = model.browse.sort == sort
                let way = current ? model.browse.sort.direction(descending: !model.browse.descending) : nil
                return TVChoice(sort.label + (way.map { " · " + $0 } ?? ""), id: sort.rawValue, isSelected: current) {
                    model.sort(by: sort)
                }
            }
        }
        .tvChoices("Filter", symbol: "line.3.horizontal.decrease", isPresented: $choosingFilter) {
            filterChoices
        }
    }

    private func siloPlaces(_ silo: SiloPagesModel) -> some View {
        HStack(spacing: 18) {
            ForEach(SiloPagesModel.Place.allCases) { place in
                TVServerLibraryChip(title: place.title, symbol: place.symbol, brand: brand,
                                    chosen: silo.place == place) { silo.place = place }
            }
        }
        .padding(.horizontal, 80)
        .lineupFocusRegion()
    }

    private func letters(scroll: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.fixed(54)), GridItem(.fixed(54))], spacing: 8) {
                ForEach(model.letters.letters) { letter in
                    Button {
                        Task {
                            guard let target = await model.jump(to: letter) else { return }
                            jumpTarget = target
                            scroll.scrollTo(target, anchor: .top)
                            await Task.yield()
                            gridFocus = target
                        }
                    } label: {
                        Text(letter.letter)
                            .font(.inter(21, .bold))
                            .frame(width: 54, height: 42)
                    }
                    .accessibilityLabel("Jump to " + letter.letter)
                }
            }
            .padding(.vertical, 20)
        }
        .frame(width: 155)
        .scrollIndicators(.hidden)
        .lineupFocusRegion()
    }

    // MARK: Library and page

    private var pages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                TVServerLibraryChip(title: model.library?.name ?? model.profile.name,
                                    symbol: model.libraries.count > 1 ? "chevron.down" : nil,
                                    chosen: false) {
                    if model.libraries.count > 1 { choosingLibrary = true }
                }
                Rectangle().fill(LineupStyle.line).frame(width: 2, height: 40).padding(.horizontal, 8)
                ForEach(ServerLibraryModel.Tab.allCases) { tab in
                    TVServerLibraryChip(title: tab.title, brand: brand, chosen: model.tab == tab) { model.tab = tab }
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 14)
        }
        .scrollClipDisabled()
        .lineupFocusRegion()
    }

    // MARK: Recommended

    @ViewBuilder
    private var recommended: some View {
        switch model.homePhase {
        case .failed(let message): failure(message)
        case .loaded where model.home.rows.isEmpty: empty("Nothing to recommend here yet.")
        case .loaded:
            ForEach(model.home.rows) { row in rowView(row) }
        default: loading
        }
    }

    private func rowView(_ row: ServerLibraryRow) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(row.title).font(.inter(30, .bold)).foregroundStyle(LineupStyle.text)
                .padding(.horizontal, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    if row.collections.isEmpty {
                        ForEach(row.items, id: \.libraryKey) { item in titleCell(item).frame(width: 240) }
                        if row.source != .fixed {
                            TVSelectable(scale: LineupStyle.cardLift, fillRadius: 16, action: { seeing = row }) {
                                VStack(spacing: 12) {
                                    Image(systemName: "chevron.right.circle.fill").font(.system(size: 54))
                                        .foregroundStyle(LineupPanelStyle.quiet)
                                    Text("See All").font(.inter(24, .semibold))
                                }
                                .foregroundStyle(LineupStyle.text)
                                .frame(width: 240, height: 360)
                                .background(LinearGradient(colors: brand.cardTints.map { $0.opacity(0.14) },
                                                           startPoint: .leading, endPoint: .trailing),
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                            }
                        }
                    } else {
                        ForEach(row.collections) { collection in collectionCell(collection).frame(width: 240) }
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .lineupFocusRegion()
        }
    }

    // MARK: Library

    @ViewBuilder
    private var library: some View {
        controls
        switch model.titlesPhase {
        case .failed(let message): failure(message)
        case .loaded where model.titles.isEmpty:
            empty(model.browse.isFiltered ? "Nothing here matches these filters." : "This library is empty.")
        case .loaded:
            LazyVGrid(columns: columns, spacing: 50) {
                ForEach(model.titles, id: \.libraryKey) { item in
                    titleCell(item, grid: true)
                        .id(item.libraryKey)
                        .onAppear {
                            if item.libraryKey == jumpTarget {
                                Task { @MainActor in
                                    await Task.yield()
                                    guard jumpTarget == item.libraryKey else { return }
                                    gridFocus = item.libraryKey
                                }
                            }
                            if item.id == model.titles.last?.id { Task { await model.loadMoreTitles() } }
                        }
                }
            }
            .padding(.horizontal, 80)
            .lineupFocusRegion()
            if model.loadingMore { ProgressView().frame(maxWidth: .infinity) }
        default: loading
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            TVServerLibraryChip(title: model.browse.sort.label, symbol: "arrow.up.arrow.down",
                                detail: model.browse.sort.direction(descending: model.browse.descending),
                                chosen: false) { choosingSort = true }
            if model.startLetter != nil {
                TVServerLibraryChip(title: "Back to Start", symbol: "arrow.up.to.line", chosen: false) {
                    jumpTarget = nil
                    model.showFromStart()
                }
            }
            TVServerLibraryChip(title: model.browse.genre ?? "Filter", symbol: "line.3.horizontal.decrease",
                                brand: brand, chosen: model.browse.isFiltered) { choosingFilter = true }
            TVServerLibraryChip(title: "Shuffle", symbol: "shuffle", chosen: false) {
                guard !shuffling else { return }
                shuffling = true
                Task {
                    if let pick = await model.shuffle() { pushed = pick }
                    shuffling = false
                }
            }
            if let total = model.titlesTotal {
                Text(total == 1 ? "1 title" : "\(total.formatted()) titles")
                    .font(.inter(20, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                    .padding(.leading, 10)
            }
        }
        .padding(.horizontal, 80).padding(.vertical, 14)
        .lineupFocusRegion()
    }

    private var filterChoices: [TVChoice] {
        var choices = CatalogMediaFilter.allCases.map { kind in
            TVChoice(kind.rawValue, id: "kind-" + kind.rawValue, isSelected: model.browse.kind == kind,
                     section: "Show") { model.setBrowse { $0.kind = kind } }
        }
        choices.append(TVChoice("Unwatched Only", id: "unwatched", isSelected: model.browse.unwatchedOnly,
                                section: "Watched") { model.setBrowse { $0.unwatchedOnly.toggle() } })
        if !model.genres.isEmpty {
            choices.append(TVChoice("All Genres", id: "genre-all", isSelected: model.browse.genre == nil,
                                    section: "Genre") { model.setBrowse { $0.genre = nil } })
            choices += model.genres.map { genre in
                TVChoice(genre, id: "genre-" + genre, isSelected: model.browse.genre == genre) {
                    model.setBrowse { $0.genre = genre }
                }
            }
        }
        return choices
    }

    // MARK: Collections

    @ViewBuilder
    private var collections: some View {
        switch model.collectionsPhase {
        case .failed(let message): failure(message)
        case .loaded where model.collections.isEmpty: empty("This library has no collections.")
        case .loaded:
            LazyVGrid(columns: columns, spacing: 50) {
                ForEach(model.collections) { collection in collectionCell(collection) }
            }
            .padding(.horizontal, 80)
            .lineupFocusRegion()
        default: loading
        }
    }

    // MARK: Cells

    @ViewBuilder
    private func titleCell(_ item: MediaItem, grid: Bool = false) -> some View {
        Group {
            if item.opensPage {
                if grid {
                    TVSelectable(drawsFocusChrome: false, action: { pushed = item }) {
                        MediaItemCard(item: item)
                            .overlay { ServerLibraryBadgesOverlay(badges: model.badges[item.id]) }
                    }
                    .focused($gridFocus, equals: item.libraryKey)
                    .tvHoldMenu(item.name, symbol: "film") { media.tvCardChoices(for: item) }
                } else {
                    TVSiloLibraryCard(item: item, badges: model.badges[item.id], open: { pushed = $0 })
                }
            } else {
                MediaPlayableCard(item: item)
                    .overlay { ServerLibraryBadgesOverlay(badges: model.badges[item.id]) }
            }
        }
    }

    private func collectionCell(_ collection: ServerLibraryCollection) -> some View {
        TVSelectable(drawsFocusChrome: false, action: { pushed = collection.item }) {
            VStack(alignment: .leading, spacing: 4) {
                MediaItemCard(item: collection.item)
                if let detail = collection.detail {
                    Text(detail).font(.inter(19, .medium)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
                }
            }
        }
    }

    // MARK: States

    private var loading: some View {
        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.inter(24)).foregroundStyle(LineupPanelStyle.quiet)
            .frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 22) {
            Text(message).font(.inter(24)).foregroundStyle(LineupPanelStyle.quiet)
                .multilineTextAlignment(.center).frame(maxWidth: 900)
            TVServerLibraryChip(title: "Try Again", symbol: "arrow.clockwise", chosen: false) {
                Task { await model.retry() }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

/// A Recommended row in full.
private struct TVServerLibraryRowScreen: View {
    @Environment(MediaLibrary.self) private var media
    let model: ServerLibraryModel
    let row: ServerLibraryRow
    @State private var items: [MediaItem]?
    @State private var failed: String?
    @State private var pushed: MediaItem?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                Text(row.title).font(.inter(40, .bold)).foregroundStyle(LineupStyle.text)
                if let items {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 290), spacing: 40, alignment: .top)],
                              spacing: 50) {
                        ForEach(items, id: \.libraryKey) { item in
                            if item.opensPage {
                                TVSelectable(drawsFocusChrome: false, action: { pushed = item }) {
                                    MediaItemCard(item: item)
                                        .overlay { ServerLibraryBadgesOverlay(badges: model.badges[item.id]) }
                                }
                                .tvHoldMenu(item.name, symbol: "film") { media.tvCardChoices(for: item) }
                            } else {
                                MediaPlayableCard(item: item)
                            }
                        }
                    }
                    .lineupFocusRegion()
                } else if let failed {
                    Text(failed).font(.inter(24)).foregroundStyle(LineupPanelStyle.quiet)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .background(LineupStyle.background.ignoresSafeArea())
        .navigationDestination(item: $pushed) { item in
            MediaBrowseDestination(item: item).environment(\.mediaStreamScope, model.profile.id)
        }
        .environment(\.mediaStreamScope, model.profile.id)
        .task {
            guard items == nil else { return }
            do { items = try await model.rowTitles(row) }
            catch { failed = error.localizedDescription }
        }
    }
}
#endif
