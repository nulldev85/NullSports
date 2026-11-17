import SwiftUI

/// One media server's own Library, laid out the way its own app lays it out:
/// one of its libraries at a time, chosen from the title, and that library's
/// Recommended rows, every title in a grid, and its collections.
struct MobileServerLibraryScreen: View {
    @Environment(MediaLibrary.self) private var media
    let profile: MediaServerProfile

    var body: some View {
        if let model = media.serverLibraryModel(for: profile) {
            MobileServerLibraryContent(model: model)
                .id(profile.id)
                .task(id: profile.id) { await model.start() }
        } else {
            Text("\(profile.name)'s own Library can't be shown right now.")
                .font(.inter(16)).foregroundStyle(LineupPanelStyle.quiet)
                .multilineTextAlignment(.center).padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MobileServerLibraryContent: View {
    @Environment(MediaLibrary.self) private var media
    @Bindable var model: ServerLibraryModel
    @State private var pushed: MediaItem?
    @State private var seeing: ServerLibraryRow?
    @State private var shuffling = false

    /// The server's own colours, from its logo, over the app's dark ground.
    private var brand: MediaServerBrand { model.profile.brand }
    /// Chevrons and spinners: the app's own quiet tone. The server's colours
    /// are laid faintly across what is chosen, as a live game's card carries
    /// its teams' colours, rather than painted on anything.
    private var accent: Color { LineupPanelStyle.quiet }

    /// What is chosen: the server's colours faint across the app's card.
    private func chosenFill<S: Shape>(_ shape: S) -> some View {
        ZStack {
            shape.fill(LineupStyle.surface)
            shape.fill(LinearGradient(colors: brand.cardTints.map { $0.opacity(0.19) },
                                      startPoint: .leading, endPoint: .trailing))
        }
    }

    /// Three across on a phone held upright, and as many more as fit on a
    /// wide screen -- the unfolded Duo, a phone on its side -- rather than
    /// three posters stretched across it.
    private let columns = MobileServerLibraryGrid.columns

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                tabs.padding(.top, 18).padding(.bottom, 22)
                switch model.tab {
                case .recommended: recommended
                case .library: library
                case .collections: collectionsGrid
                }
            }
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .tint(LineupStyle.text)
        .background(LineupStyle.background.ignoresSafeArea())
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .navigationDestination(item: $seeing) { row in MobileServerLibraryRowScreen(model: model, row: row) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if case .failed(let message) = model.librariesPhase {
                failure(message)
            } else if model.libraries.count > 1 {
                Menu {
                    ForEach(model.libraries, id: \.id) { library in
                        Button {
                            model.choose(library)
                        } label: {
                            if library.id == model.library?.id {
                                Label(library.name, systemImage: "checkmark")
                            } else {
                                Text(library.name)
                            }
                        }
                    }
                } label: {
                    title(chevron: true)
                }
                .accessibilityLabel("Choose a library, \(model.library?.name ?? "")")
            } else {
                title(chevron: false)
            }
            HStack(spacing: 7) {
                MediaServerLogo(brand: brand).frame(width: 16, height: 16)
                Text(model.profile.name)
                    .font(.inter(15, .medium)).foregroundStyle(LineupPanelStyle.quiet)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func title(chevron: Bool) -> some View {
        HStack(spacing: 10) {
            Text(model.library?.name ?? model.profile.name)
                .font(.inter(32, .heavy)).foregroundStyle(LineupStyle.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(accent)
            }
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ServerLibraryModel.Tab.allCases) { tab in
                    let chosen = model.tab == tab
                    Button {
                        model.tab = tab
                    } label: {
                        Text(tab.title)
                            .font(.inter(17, chosen ? .bold : .semibold))
                            .foregroundStyle(chosen ? LineupStyle.text : LineupPanelStyle.quiet)
                            .padding(.horizontal, 22).frame(height: 44)
                            .background {
                                if chosen { chosenFill(Capsule()) } else { Capsule().fill(LineupStyle.surface) }
                            }
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
                            .animation(.easeOut(duration: 0.18), value: chosen)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Recommended

    @ViewBuilder
    private var recommended: some View {
        switch model.homePhase {
        case .failed(let message):
            failure(message)
        case .loaded where model.home.rows.isEmpty:
            empty("Nothing to recommend here yet.")
        case .loaded:
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(model.home.rows) { row in rowView(row) }
            }
        default:
            loading
        }
    }

    private func rowView(_ row: ServerLibraryRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if row.collections.isEmpty {
                    Button {
                        seeing = row
                    } label: {
                        HStack(spacing: 8) {
                            rowTitle(row)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 17, weight: .bold)).foregroundStyle(accent)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    rowTitle(row)
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    if row.collections.isEmpty {
                        ForEach(row.items, id: \.libraryKey) { item in
                            titleCell(item).frame(width: 128)
                        }
                    } else {
                        ForEach(row.collections) { collection in
                            collectionCell(collection).frame(width: 128)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func rowTitle(_ row: ServerLibraryRow) -> some View {
        Text(row.title).font(.inter(24, .heavy)).foregroundStyle(LineupStyle.text).lineLimit(1)
    }

    // MARK: Library

    @ViewBuilder
    private var library: some View {
        controls.padding(.bottom, 18)
        switch model.titlesPhase {
        case .failed(let message):
            failure(message)
        case .loaded where model.titles.isEmpty:
            empty(model.browse.isFiltered ? "Nothing here matches these filters." : "This library is empty.")
        case .loaded:
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(model.titles, id: \.libraryKey) { item in
                    titleCell(item)
                        .onAppear {
                            if item.id == model.titles.last?.id { Task { await model.loadMoreTitles() } }
                        }
                }
            }
            .padding(.horizontal, 16)
            if model.loadingMore {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        default:
            loading
        }
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(ServerLibrarySort.allCases, id: \.self) { sort in
                        Button {
                            model.sort(by: sort)
                        } label: {
                            if model.browse.sort == sort {
                                Label(sort.label, systemImage: model.browse.descending ? "arrow.down" : "arrow.up")
                            } else {
                                Text(sort.label)
                            }
                        }
                    }
                } label: {
                    control(symbol: "arrow.up.arrow.down", title: model.browse.sort.label,
                            detail: model.browse.sort.direction(descending: model.browse.descending))
                }
                Menu {
                    Picker("Show", selection: Binding(get: { model.browse.kind },
                                                      set: { kind in model.setBrowse { $0.kind = kind } })) {
                        ForEach(CatalogMediaFilter.allCases, id: \.self) { kind in Text(kind.rawValue).tag(kind) }
                    }
                    Toggle("Unwatched Only", isOn: Binding(get: { model.browse.unwatchedOnly },
                                                           set: { on in model.setBrowse { $0.unwatchedOnly = on } }))
                    if !model.genres.isEmpty {
                        Menu("Genre") {
                            Picker("Genre", selection: Binding(get: { model.browse.genre },
                                                               set: { genre in model.setBrowse { $0.genre = genre } })) {
                                Text("All Genres").tag(String?.none)
                                ForEach(model.genres, id: \.self) { genre in Text(genre).tag(String?.some(genre)) }
                            }
                        }
                    }
                    if model.browse.isFiltered {
                        Button("Clear Filters", role: .destructive) {
                            model.setBrowse { $0.genre = nil; $0.kind = .all; $0.unwatchedOnly = false }
                        }
                    }
                } label: {
                    control(symbol: "line.3.horizontal.decrease", title: model.browse.genre ?? "Filter",
                            detail: nil, active: model.browse.isFiltered)
                }
                Button {
                    guard !shuffling else { return }
                    shuffling = true
                    Task {
                        if let pick = await model.shuffle() { pushed = pick }
                        shuffling = false
                    }
                } label: {
                    control(symbol: "shuffle", title: "Shuffle", detail: nil)
                }
                .buttonStyle(.plain)
                .disabled(shuffling)
            }
            .padding(.horizontal, 16)
        }
    }

    private func control(symbol: String, title: String, detail: String?, active: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 16, weight: .bold))
            Text(title).font(.inter(17, .semibold))
            if let detail {
                Text(detail).font(.inter(13, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
            }
        }
        .foregroundStyle(LineupStyle.text)
        .padding(.horizontal, 16).frame(height: 44)
        .background {
            if active { chosenFill(Capsule()) } else { Capsule().fill(LineupStyle.surface) }
        }
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
    }

    // MARK: Collections

    @ViewBuilder
    private var collectionsGrid: some View {
        switch model.collectionsPhase {
        case .failed(let message):
            failure(message)
        case .loaded where model.collections.isEmpty:
            empty("This library has no collections.")
        case .loaded:
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(model.collections) { collection in collectionCell(collection) }
            }
            .padding(.horizontal, 16)
        default:
            loading
        }
    }

    // MARK: Cells

    @ViewBuilder
    private func titleCell(_ item: MediaItem) -> some View {
        Group {
            if item.opensPage {
                MediaItemCard(item: item)
                    .lineupHoldMenu(item.name, symbol: "film", items: { media.cardMenuItems(for: item) }) {
                        pushed = item
                    }
            } else {
                MediaPlayableCard(item: item)
            }
        }
        .overlay { ServerLibraryBadgesOverlay(badges: model.badges[item.id]) }
    }

    private func collectionCell(_ collection: ServerLibraryCollection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MediaItemCard(item: collection.item)
                .lineupHoldMenu(collection.item.name, symbol: "rectangle.stack", items: { [] }) {
                    pushed = collection.item
                }
            if let detail = collection.detail {
                Text(detail).font(.inter(13, .medium)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
            }
        }
    }

    // MARK: States

    private var loading: some View {
        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.inter(16)).foregroundStyle(LineupPanelStyle.quiet)
            .frame(maxWidth: .infinity).padding(.vertical, 60).padding(.horizontal, 24)
            .multilineTextAlignment(.center)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(.inter(15)).foregroundStyle(LineupPanelStyle.quiet)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await model.retry() } }
                .lineupProminentButton()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }
}

/// A Recommended row in full.
struct MobileServerLibraryRowScreen: View {
    @Environment(MediaLibrary.self) private var media
    let model: ServerLibraryModel
    let row: ServerLibraryRow
    @State private var items: [MediaItem]?
    @State private var failed: String?
    @State private var pushed: MediaItem?

    var body: some View {
        ScrollView {
            if let items {
                LazyVGrid(columns: MobileServerLibraryGrid.columns,
                          spacing: 22) {
                    ForEach(items, id: \.libraryKey) { item in
                        Group {
                            if item.opensPage {
                                MediaItemCard(item: item)
                                    .lineupHoldMenu(item.name, symbol: "film",
                                                    items: { media.cardMenuItems(for: item) }) { pushed = item }
                            } else {
                                MediaPlayableCard(item: item)
                            }
                        }
                        .overlay { ServerLibraryBadgesOverlay(badges: model.badges[item.id]) }
                    }
                }
                .padding(16)
            } else if let failed {
                Text(failed).font(.inter(15)).foregroundStyle(LineupPanelStyle.quiet)
                    .multilineTextAlignment(.center).padding(40)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
            }
        }
        .tint(LineupStyle.text)
        .background(LineupStyle.background.ignoresSafeArea())
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .task {
            guard items == nil else { return }
            do { items = try await model.rowTitles(row) }
            catch { failed = error.localizedDescription }
        }
    }
}

/// The server Library's grid: posters about as wide as a phone's three
/// across, as many as the screen holds.
enum MobileServerLibraryGrid {
    static let columns = [GridItem(.adaptive(minimum: 104, maximum: 168), spacing: 12, alignment: .top)]
}
