import SwiftUI

/// Each IPTV provider's films and shows as a folder in the Library, the way
/// collections are: one tile a provider, by the name it was given.
struct MobileLibraryVODRow: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.mobileShelfBleed) private var bleed

    static let rowID = "builtin:iptv-vod"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VOD")
                .font(.inter(14, .heavy))
                .padding(.horizontal, LineupPanelStyle.inset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(media.providerVODAccounts) { provider in
                        NavigationLink { MobileProviderVODView(provider: provider) } label: {
                            tile(provider)
                        }
                        .lineupFlatButton()
                    }
                }
                .padding(.leading, LineupPanelStyle.inset + bleed.leading)
                .padding(.trailing, LineupPanelStyle.inset + bleed.trailing)
            }
            .mobileShelfRowBleed(bleed)
        }
        .padding(.vertical, 4)
    }

    private func tile(_ provider: XtreamProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LineupPanelStyle.fill
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(LineupStyle.highlight)
            }
            .frame(height: 205 * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(provider.name).font(.inter(.subheadline, .bold)).lineLimit(1)
            Text("Movies and shows").font(.inter(.caption2)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
        }
        .frame(width: 205, alignment: .leading).padding(14)
        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundStyle(LineupStyle.text)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this provider's movie and show categories")
    }
}

/// One provider's films and shows: its categories, and the titles of the one
/// chosen, with Movies and Shows on tabs.
///
/// Wide -- a Duo open, a phone on its side -- the categories run down the
/// left and the chosen one's titles fill the right, under the tabs. Upright,
/// the tabs, then the categories as a row of chips, then the titles.
struct MobileProviderVODView: View {
    @Environment(MediaLibrary.self) private var media
    let provider: XtreamProfile

    private enum Kind: String, CaseIterable, Identifiable {
        case movies = "Movies", shows = "Shows"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .movies
    @State private var categories: (films: [MediaItem], shows: [MediaItem])?
    @State private var failed = false
    /// The category chosen on each tab, by id.
    @State private var chosen: [Kind: String] = [:]
    @State private var titles: [MediaItem] = []
    @State private var loadingTitles = false

    private static let splitWidth: CGFloat = 700

    private var list: [MediaItem] {
        kind == .movies ? categories?.films ?? [] : categories?.shows ?? []
    }

    private var selected: MediaItem? {
        let all = list
        return all.first { $0.id == chosen[kind] } ?? all.first
    }

    var body: some View {
        GeometryReader { bounds in
            Group {
                if categories == nil {
                    status
                } else if bounds.size.width >= Self.splitWidth {
                    HStack(spacing: 0) {
                        sidebar.frame(width: min(320, bounds.size.width * 0.32))
                        Rectangle().fill(LineupPanelStyle.divider).frame(width: 1)
                        VStack(spacing: 12) {
                            tabs.padding(.horizontal, 16).padding(.top, 12)
                            grid
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        tabs.padding(.horizontal, 16).padding(.top, 8)
                        chips
                        grid
                    }
                }
            }
            .frame(width: bounds.size.width, height: bounds.size.height, alignment: .top)
        }
        .background(LineupStyle.background.ignoresSafeArea())
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: provider.id) { await load() }
        .task(id: selected?.libraryKey) { await loadTitles() }
    }

    // MARK: Parts

    private var tabs: some View {
        Picker("Show", selection: $kind) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// The categories down the left, the chosen one marked.
    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(list, id: \.libraryKey) { category in
                    let isChosen = category.id == selected?.id
                    Button { choose(category) } label: {
                        HStack(spacing: 10) {
                            Text(category.name)
                                .font(.inter(.subheadline, isChosen ? .bold : .medium))
                                .foregroundStyle(isChosen ? LineupStyle.text : LineupStyle.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 6)
                            if let count = category.childCount {
                                Text(count.formatted()).font(.interDigits(13, .medium))
                                    .foregroundStyle(LineupPanelStyle.quiet)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(isChosen ? LineupPanelStyle.fill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    /// The categories as a row of chips, upright.
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(list, id: \.libraryKey) { category in
                        let isChosen = category.id == selected?.id
                        Button { choose(category) } label: {
                            Text(category.name)
                                .font(.inter(.subheadline, .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 14).frame(height: 34)
                                .foregroundStyle(isChosen ? LineupStyle.onHighlight : LineupStyle.text)
                                .background(isChosen ? LineupStyle.highlight : LineupPanelStyle.fill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(category.libraryKey)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 38)
            .onChange(of: kind) { _, _ in
                if let key = selected?.libraryKey { proxy.scrollTo(key, anchor: .center) }
            }
        }
    }

    /// The chosen category's titles.
    private var grid: some View {
        ScrollView {
            if loadingTitles && titles.isEmpty {
                ProgressView().padding(.top, 40)
            } else if titles.isEmpty {
                Text(list.isEmpty ? "\(provider.name) has no \(kind.rawValue.lowercased())." : "Nothing in this category.")
                    .font(.inter(.subheadline, .medium))
                    .foregroundStyle(LineupPanelStyle.quiet)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)],
                          spacing: 16) {
                    ForEach(titles, id: \.libraryKey) { item in
                        NavigationLink(value: item) { MediaItemCard(item: item, shape: .poster) }
                            .lineupFlatButton()
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
    }

    private var status: some View {
        VStack(spacing: 12) {
            if failed {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(LineupIconTile.orange)
                Text("\(provider.name) didn’t send its list.").font(.inter(.headline))
                Button("Try Again") { Task { await load() } }.lineupButtonStyle()
            } else {
                ProgressView()
                Text("Loading \(provider.name)’s list…").font(.inter(.subheadline, .medium))
            }
        }
        .foregroundStyle(LineupStyle.text)
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    // MARK: Loading

    private func choose(_ category: MediaItem) {
        guard chosen[kind] != category.id else { return }
        chosen[kind] = category.id
    }

    private func load() async {
        failed = false
        let found = await media.providerVODCategories(provider.id)
        guard !Task.isCancelled else { return }
        categories = found
        failed = found == nil
        // A provider with shows and no films opens on its shows.
        if let found, found.films.isEmpty, !found.shows.isEmpty { kind = .shows }
    }

    private func loadTitles() async {
        guard let category = selected else { titles = []; return }
        loadingTitles = true
        titles = []
        let found = (try? await media.items(in: category)) ?? []
        guard !Task.isCancelled, category.id == selected?.id else { return }
        titles = found
        loadingTitles = false
    }
}
