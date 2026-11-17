import SwiftUI

/// Each IPTV provider's films and shows as a folder in the Library, the way
/// collections are: one tile a provider, by the name it was given.
struct MobileLibraryVODRow: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.mobileShelfBleed) private var bleed

    static let rowID = MediaLibrary.vodRowID

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
///
/// A category's titles are kept once read, so going back to one is instant,
/// and the titles on screen stay until the next category's are ready rather
/// than giving way to a spinner: changing category or tab is a crossfade
/// from one grid to the next.
struct MobileProviderVODView: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// Each category's titles once read, by the category's key.
    @State private var titlesByCategory: [String: [MediaItem]] = [:]
    @State private var wide = false
    /// A title chosen, for its page.
    @State private var pushed: MediaItem?

    private static let splitWidth: CGFloat = 700

    private var list: [MediaItem] {
        kind == .movies ? categories?.films ?? [] : categories?.shows ?? []
    }

    private var selected: MediaItem? {
        let all = list
        return all.first { $0.id == chosen[kind] } ?? all.first
    }

    private var transition: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.22)
    }

    var body: some View {
        Group {
            if categories == nil {
                status
            } else if wide {
                HStack(spacing: 0) {
                    sidebar.frame(width: 300)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Wide or not is decided as the size changes, not worked out again
        // on every redraw.
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.splitWidth } action: { wide = $0 }
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LineupPresentationStyle.ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // A title's page, as from any shelf in the Library.
        .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
        .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
        .task(id: provider.id) { await load() }
        .task(id: selected?.libraryKey) { await loadTitles(for: selected) }
    }

    // MARK: Parts

    private var tabs: some View {
        Picker("Show", selection: Binding(get: { kind }, set: { new in
            withAnimation(transition) { kind = new }
        })) {
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
        .id(kind)
    }

    /// The categories as a row of chips, upright.
    private var chips: some View {
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
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 38)
        // Each tab's chips start at their own beginning.
        .id(kind)
    }

    /// The chosen category's titles, crossfading to the next category's
    /// once they are in hand.
    private var grid: some View {
        let key = selected?.libraryKey ?? ""
        let titles = titlesByCategory[key]
        return ZStack(alignment: .top) {
            if let titles {
                if titles.isEmpty {
                    Text("Nothing in this category.")
                        .font(.inter(.subheadline, .medium))
                        .foregroundStyle(LineupPanelStyle.quiet)
                        .padding(.top, 40)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)],
                                  spacing: 16) {
                            ForEach(titles, id: \.libraryKey) { item in cell(item) }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 24)
                    }
                }
            } else if list.isEmpty {
                Text("\(provider.name) has no \(kind.rawValue.lowercased()).")
                    .font(.inter(.subheadline, .medium))
                    .foregroundStyle(LineupPanelStyle.quiet)
                    .padding(.top, 40)
            } else {
                ProgressView().padding(.top, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(key)
        .transition(.opacity)
        .animation(transition, value: key)
    }

    /// A title as the Library's grids draw it: its page on a tap, the
    /// Library's choices on a hold.
    @ViewBuilder
    private func cell(_ item: MediaItem) -> some View {
        if item.opensPage {
            MediaItemCard(item: item, shape: .poster)
                .lineupHoldMenu(item.name, symbol: item.isSeries ? "tv" : "film",
                                items: { media.cardMenuItems(for: item) }) { pushed = item }
        } else {
            MediaPlayableCard(item: item, shape: .poster)
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
        withAnimation(transition) { chosen[kind] = category.id }
    }

    private func load() async {
        failed = false
        let found = await media.providerVODCategories(provider.id)
        guard !Task.isCancelled else { return }
        categories = found
        failed = found == nil
        guard let found else { return }
        // A provider with shows and no films opens on its shows.
        if found.films.isEmpty, !found.shows.isEmpty { kind = .shows }
        // The other tab's first category is read now, so changing tab finds
        // its titles waiting.
        for first in [found.films.first, found.shows.first].compactMap({ $0 }) {
            await loadTitles(for: first)
        }
    }

    private func loadTitles(for category: MediaItem?) async {
        guard let category, titlesByCategory[category.libraryKey] == nil else { return }
        let found = (try? await media.items(in: category)) ?? []
        guard !Task.isCancelled else { return }
        withAnimation(transition) { titlesByCategory[category.libraryKey] = found }
    }
}
