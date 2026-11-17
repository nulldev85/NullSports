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
                        TVServerLibraryChip(title: server.name, symbol: "externaldrive.fill",
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

/// A chip in one of the Library's rows of choices: filled when chosen.
struct TVServerLibraryChip: View {
    let title: String
    var symbol: String? = nil
    var detail: String? = nil
    let chosen: Bool
    let action: () -> Void

    var body: some View {
        TVSelectable(scale: LineupStyle.controlLift, fillRadius: 30, drawsFocusChrome: false, action: action) {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol).font(.system(size: 22, weight: .bold)) }
                Text(title).font(.inter(24, chosen ? .bold : .semibold)).lineLimit(1)
                if let detail { Text(detail).font(.inter(19, .semibold)).opacity(0.6) }
            }
            .foregroundStyle(chosen ? Color.black : LineupStyle.text)
            .padding(.horizontal, 26).frame(height: 60)
            .background(chosen ? Color.white : LineupStyle.surface, in: Capsule())
        }
    }
}

/// One server's own Library on the television: the same three pages as on
/// the phone, as rows of choices and cards the remote moves between.
struct TVServerLibraryScreen: View {
    @Environment(MediaLibrary.self) private var media
    let profile: MediaServerProfile
    @State private var model: ServerLibraryModel?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let model, model.profile.id == profile.id {
                TVServerLibraryContent(model: model)
            } else {
                VStack(spacing: 0) {
                    TVServerLibrarySwitcher()
                    if unavailable {
                        Text("\(profile.name)'s own Library can't be shown right now.")
                            .font(.inter(24)).foregroundStyle(LineupPanelStyle.quiet)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task(id: profile.id) {
            guard model?.profile.id != profile.id else { return }
            guard let browser = media.serverLibraryBrowser(for: profile) else { unavailable = true; return }
            unavailable = false
            let made = ServerLibraryModel(profile: profile, browser: browser)
            model = made
            await made.start()
        }
    }
}

private struct TVServerLibraryContent: View {
    @Environment(MediaLibrary.self) private var media
    @Bindable var model: ServerLibraryModel
    @State private var pushed: MediaItem?
    @State private var seeing: ServerLibraryRow?
    @State private var choosingLibrary = false
    @State private var choosingSort = false
    @State private var choosingFilter = false
    @State private var shuffling = false

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 290), spacing: 40, alignment: .top)]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 34) {
                TVServerLibrarySwitcher()
                pages
                switch model.tab {
                case .recommended: recommended
                case .library: library
                case .collections: collections
                }
            }
            .padding(.top, 10).padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .navigationDestination(item: $seeing) { row in TVServerLibraryRowScreen(model: model, row: row) }
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
                    TVServerLibraryChip(title: tab.title, chosen: model.tab == tab) { model.tab = tab }
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
                                    Text("See All").font(.inter(24, .semibold))
                                }
                                .foregroundStyle(LineupStyle.text)
                                .frame(width: 240, height: 360)
                                .background(LineupStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    titleCell(item)
                        .onAppear {
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
            TVServerLibraryChip(title: model.browse.genre ?? "Filter", symbol: "line.3.horizontal.decrease",
                                chosen: model.browse.isFiltered) { choosingFilter = true }
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
    private func titleCell(_ item: MediaItem) -> some View {
        Group {
            if item.opensPage {
                TVSelectable(drawsFocusChrome: false, action: { pushed = item }) {
                    MediaItemCard(item: item)
                        .overlay { ServerLibraryBadgesOverlay(badges: model.badges[item.id]) }
                }
                .tvHoldMenu(item.name, symbol: "film") { media.tvCardChoices(for: item) }
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
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .task {
            guard items == nil else { return }
            do { items = try await model.rowTitles(row) }
            catch { failed = error.localizedDescription }
        }
    }
}
#endif
