import SwiftUI

/// The provider's films and series: a row per category, Continue Watching on
/// top, search across the whole catalogue, and a page per title.
///
/// One file for both platforms, as Library is. The layout differs where a
/// remote and a thumb want different things -- a shelf of episodes on the
/// television, a list of them on the phone -- and is shared everywhere else.
struct OnDemandView: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    @AppStorage("Lineup.onDemandKind") private var kindRaw = OnDemandKind.movies.rawValue
    @State private var path = NavigationPath()
    @State private var playing: OnDemandPlayRequest?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(OnDemandBackdrop().ignoresSafeArea())
                #if !os(tvOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .navigationDestination(for: OnDemandRoute.self) { route in
                    destination(route)
                }
        }
        .environment(\.onDemandOpen, OnDemandAction { path.append($0) })
        .environment(\.onDemandPlay, OnDemandPlayAction { playing = $0 })
        .fullScreenCover(item: $playing) { request in
            OnDemandPlayer(request: request).environmentObject(onDemand)
        }
        // Another provider's pages mean nothing here.
        .onChange(of: onDemand.profileID) { _, _ in
            path = NavigationPath()
            playing = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if onDemand.profileID == nil {
            OnDemandMessage(symbol: "film.stack", title: "Connect a Provider",
                            detail: "Add an IPTV provider in Account to browse its movies and series.")
        } else if onDemand.state == .empty {
            OnDemandMessage(symbol: "film.stack", title: "Nothing On Demand",
                            detail: "This provider doesn't offer movies or series.")
        } else if onDemand.categories.isEmpty {
            if case .failed(let message) = onDemand.state {
                OnDemandMessage(symbol: "exclamationmark.triangle", title: "Can't Load On Demand",
                                detail: message, actionTitle: "Try Again") { onDemand.refresh() }
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Loading movies and series…").font(.inter(.headline))
                }
                .foregroundStyle(LineupStyle.lightPurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            OnDemandHome(kindRaw: $kindRaw)
        }
    }

    @ViewBuilder
    private func destination(_ route: OnDemandRoute) -> some View {
        switch route {
        case .title(let title): OnDemandDetailScreen(title: title)
        case .category(let kind, let category): OnDemandCategoryScreen(kind: kind, category: category)
        case .search(let kind): OnDemandSearchScreen(kind: kind)
        }
    }
}

// MARK: - Navigation and playback

enum OnDemandRoute: Hashable {
    case title(OnDemandTitle)
    case category(OnDemandKind, OnDemandCategory)
    case search(OnDemandKind)
}

/// What a card does when chosen, handed down rather than threaded through
/// every initialiser between the stack and the card.
struct OnDemandAction {
    let perform: (OnDemandRoute) -> Void
    init(_ perform: @escaping (OnDemandRoute) -> Void) { self.perform = perform }
    func callAsFunction(_ route: OnDemandRoute) { perform(route) }
}

struct OnDemandPlayAction {
    let perform: (OnDemandPlayRequest) -> Void
    init(_ perform: @escaping (OnDemandPlayRequest) -> Void) { self.perform = perform }
    func callAsFunction(_ request: OnDemandPlayRequest) { perform(request) }
}

private struct OnDemandOpenKey: EnvironmentKey {
    static let defaultValue = OnDemandAction { _ in }
}

private struct OnDemandPlayKey: EnvironmentKey {
    static let defaultValue = OnDemandPlayAction { _ in }
}

extension EnvironmentValues {
    var onDemandOpen: OnDemandAction {
        get { self[OnDemandOpenKey.self] }
        set { self[OnDemandOpenKey.self] = newValue }
    }

    var onDemandPlay: OnDemandPlayAction {
        get { self[OnDemandPlayKey.self] }
        set { self[OnDemandPlayKey.self] = newValue }
    }
}

struct OnDemandPlayRequest: Identifiable {
    let id = UUID()
    /// What is playing, with everything a Continue Watching card needs.
    let record: OnDemandPlayback
    /// The episode after this one, filed as up next when this one finishes.
    let upNext: OnDemandPlayback?
    let startAt: TimeInterval?
    let overview: String?
    /// The provider it was opened under.
    let profileID: UUID?
}

private struct OnDemandPlayer: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    let request: OnDemandPlayRequest

    var body: some View {
        let urls = onDemand.playbackURLs(for: request.record)
        #if os(tvOS)
        PlayerView(urls: urls, title: heading, isLive: false,
                   initialPosition: request.startAt) { position, duration in
            report(position, duration)
        }
        #else
        MobilePlayerView(name: heading, urls: urls, isLive: false,
                         synopsis: synopsis, initialPosition: request.startAt) { position, duration in
            report(position, duration)
        }
        #endif
    }

    private var heading: String {
        let record = request.record
        guard let series = record.seriesName else { return record.title }
        return [series, record.episodeCode].compactMap { $0 }.joined(separator: " · ")
    }

    #if !os(tvOS)
    private var synopsis: MobilePlayerSynopsis {
        let record = request.record
        let heading = record.seriesName == nil
            ? record.title
            : [record.seriesName, record.episodeCode, record.title].compactMap { $0 }.joined(separator: " · ")
        let detail = record.duration > 0 ? OnDemandNaming.runtime(Int(record.duration)) : nil
        return MobilePlayerSynopsis(heading: heading, detail: detail, overview: request.overview)
    }
    #endif

    private func report(_ position: TimeInterval, _ duration: TimeInterval) {
        onDemand.track(request.record, profileID: request.profileID, position: position,
                       duration: duration, upNext: request.upNext)
    }
}

extension OnDemandPlayback {
    static func movie(_ title: OnDemandTitle, detail: OnDemandMovieDetail?) -> OnDemandPlayback {
        OnDemandPlayback(
            kind: .movie, streamID: title.providerID,
            containerExtension: detail?.containerExtension ?? title.containerExtension ?? "mp4",
            title: title.name, artwork: title.artwork ?? detail?.facts.poster,
            still: detail?.facts.backdrops.first, seriesID: nil, seriesName: nil,
            season: nil, episode: nil, position: 0,
            duration: TimeInterval(detail?.facts.durationSeconds ?? 0),
            updatedAt: Date(), completed: false, isUpNext: false)
    }

    static func episode(_ episode: OnDemandEpisode, of series: OnDemandTitle,
                        detail: OnDemandSeriesDetail) -> OnDemandPlayback {
        OnDemandPlayback(
            kind: .episode, streamID: episode.id, containerExtension: episode.containerExtension,
            title: episode.title, artwork: series.artwork ?? detail.facts.poster,
            still: episode.still ?? detail.facts.backdrops.first,
            seriesID: series.providerID, seriesName: series.name,
            season: episode.season, episode: episode.number, position: 0,
            duration: TimeInterval(episode.durationSeconds ?? 0),
            updatedAt: Date(), completed: false, isUpNext: false)
    }

    /// Enough of a title to open its page from a Continue Watching card.
    var detailTitle: OnDemandTitle {
        OnDemandTitle(kind: seriesID == nil ? .movies : .series, providerID: seriesID ?? streamID,
                      rawName: displayName, name: displayName, artwork: artwork, rating: nil,
                      year: nil, added: nil, categoryIDs: [],
                      containerExtension: kind == .movie ? containerExtension : nil)
    }
}

extension OnDemandLibrary {
    /// Plays an episode and knows what comes after it, so finishing it files
    /// the next one as up next.
    func playRequest(for episode: OnDemandEpisode, of series: OnDemandTitle,
                     detail: OnDemandSeriesDetail, fromStart: Bool = false) -> OnDemandPlayRequest {
        let next = OnDemandProgressPolicy.nextEpisode(after: episode.id, in: detail.seasons) {
            self.isWatched(.episode, $0)
        }
        return OnDemandPlayRequest(
            record: .episode(episode, of: series, detail: detail),
            upNext: next.map { OnDemandPlayback.episode($0, of: series, detail: detail) },
            startAt: fromStart ? nil : resumePosition(.episode, episode.id),
            overview: episode.plot ?? detail.facts.plot, profileID: profileID)
    }

    func playRequest(for movie: OnDemandTitle, detail: OnDemandMovieDetail?,
                     fromStart: Bool = false) -> OnDemandPlayRequest {
        OnDemandPlayRequest(record: .movie(movie, detail: detail), upNext: nil,
                            startAt: fromStart ? nil : resumePosition(.movie, movie.providerID),
                            overview: detail?.facts.plot, profileID: profileID)
    }

    /// Resumes a Continue Watching card. An episode's series is looked up
    /// first -- usually already in hand -- so that finishing it still moves
    /// the series on to the next one.
    func playRequest(resuming record: OnDemandPlayback) async -> OnDemandPlayRequest {
        let fallback = OnDemandPlayRequest(record: record, upNext: nil,
                                           startAt: OnDemandProgressPolicy.resumePosition(record),
                                           overview: nil, profileID: profileID)
        guard record.kind == .episode, record.seriesID != nil,
              let detail = try? await seriesDetail(record.detailTitle),
              let episode = detail.seasons.flatMap(\.episodes).first(where: { $0.id == record.streamID })
        else { return fallback }
        return playRequest(for: episode, of: record.detailTitle, detail: detail)
    }
}

// MARK: - Home

private struct OnDemandHome: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    @Environment(\.onDemandOpen) private var navigate
    @Binding var kindRaw: String
    #if os(tvOS)
    @State private var optionsVisible = false
    #endif
    @State private var clearingHistory = false

    private var kind: OnDemandKind { OnDemandKind(rawValue: kindRaw) ?? .movies }

    var body: some View {
        let categories = onDemand.categories[kind] ?? []
        let continueWatching = onDemand.continueWatching
        ScrollView {
            LazyVStack(alignment: .leading, spacing: OnDemandMetrics.sectionSpacing) {
                header
                if !continueWatching.isEmpty {
                    OnDemandContinueShelf(records: continueWatching)
                }
                if categories.isEmpty {
                    Text("This provider has no \(kind.title.lowercased()).")
                        .font(.inter(.callout)).foregroundStyle(LineupStyle.secondary)
                        .padding(.horizontal, OnDemandMetrics.gutter)
                }
                ForEach(categories) { category in
                    OnDemandCategoryShelf(kind: kind, category: category)
                }
            }
            .padding(.bottom, OnDemandMetrics.gutter)
        }
        .scrollClipDisabled()
        .confirmationDialog("Clear watch history?", isPresented: $clearingHistory,
                            titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { onDemand.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Continue Watching and watched status for this provider's movies and series on this device.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OnDemandMetrics.headerSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("On Demand").font(OnDemandMetrics.pageTitleFont)
                    .foregroundStyle(LineupStyle.text)
                Spacer(minLength: 12)
                #if !os(tvOS)
                Button { navigate(.search(kind)) } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Search")
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { onDemand.refresh() }
                    if !onDemand.playbacks.isEmpty {
                        Button("Clear Watch History", systemImage: "clock.arrow.circlepath",
                               role: .destructive) { clearingHistory = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 19, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("On Demand options")
                #endif
            }
            .foregroundStyle(LineupStyle.lightPurple)
            HStack(spacing: 12) {
                ForEach(OnDemandKind.allCases) { option in
                    OnDemandPill(title: option.title, selected: option == kind) { kindRaw = option.rawValue }
                }
                #if os(tvOS)
                OnDemandPill(title: "Search", systemImage: "magnifyingglass", selected: false) {
                    navigate(.search(kind))
                }
                OnDemandPill(title: "Options", systemImage: "ellipsis", selected: false) {
                    optionsVisible = true
                }
                .confirmationDialog("On Demand", isPresented: $optionsVisible, titleVisibility: .visible) {
                    Button("Refresh", systemImage: "arrow.clockwise") { onDemand.refresh() }
                    if !onDemand.playbacks.isEmpty {
                        Button("Clear Watch History", role: .destructive) { clearingHistory = true }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                #endif
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .padding(.horizontal, OnDemandMetrics.gutter)
        .padding(.top, OnDemandMetrics.headerTop)
    }
}

// MARK: - Shelves

private struct OnDemandShelfHeading: View {
    let title: String
    var detail: String?
    var seeAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(OnDemandMetrics.shelfTitleFont).lineLimit(1)
                .foregroundStyle(LineupStyle.text)
            if let detail {
                Text(detail).font(.inter(.caption, .semibold))
                    .foregroundStyle(LineupStyle.secondary)
            }
            Spacer(minLength: 8)
            #if !os(tvOS)
            if let seeAll {
                Button("See All", action: seeAll)
                    .font(.inter(.subheadline, .semibold))
                    .foregroundStyle(LineupStyle.highlight)
            }
            #endif
        }
        .padding(.horizontal, OnDemandMetrics.gutter)
    }
}

private struct OnDemandContinueShelf: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    @Environment(\.onDemandPlay) private var play
    @Environment(\.onDemandOpen) private var navigate
    let records: [OnDemandPlayback]

    var body: some View {
        VStack(alignment: .leading, spacing: OnDemandMetrics.shelfHeadingSpacing) {
            OnDemandShelfHeading(title: "Continue Watching")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: OnDemandMetrics.cardSpacing) {
                    ForEach(records) { record in
                        OnDemandPressable(action: { resume(record) }) {
                            OnDemandContinueCard(record: record)
                        }
                        .contextMenu {
                            Button("Go to Details", systemImage: "info.circle") {
                                navigate(.title(record.detailTitle))
                            }
                            Button("Mark as Watched", systemImage: "checkmark.circle") {
                                onDemand.setWatched(true, record, upNext: nil)
                            }
                            Button("Remove from Continue Watching", systemImage: "rectangle.stack.badge.minus",
                                   role: .destructive) {
                                onDemand.removeFromContinueWatching(record)
                            }
                        }
                    }
                }
                .padding(.horizontal, OnDemandMetrics.gutter)
                .padding(.vertical, OnDemandMetrics.liftRoom)
            }
            .scrollClipDisabled()
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func resume(_ record: OnDemandPlayback) {
        Task { play(await onDemand.playRequest(resuming: record)) }
    }
}

private struct OnDemandCategoryShelf: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    @Environment(\.onDemandOpen) private var navigate
    let kind: OnDemandKind
    let category: OnDemandCategory

    /// Enough to fill a screen twice over. The rest is a press of See All away.
    private let shelfLimit = 30

    var body: some View {
        let titles = onDemand.titles(kind, in: category.id)
        let load = onDemand.shelfLoads[OnDemandLibrary.shelfKey(kind, category.id)]
        Group {
            // A provider lists plenty of categories with nothing in them. Once
            // that is known the shelf takes no room at all.
            if let titles, titles.isEmpty, load != .loading, load != .failed {
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: OnDemandMetrics.shelfHeadingSpacing) {
                    OnDemandShelfHeading(title: category.name,
                                         detail: titles.map { "\($0.count)" },
                                         seeAll: seeAll(titles))
                    row(titles: titles, load: load)
                }
            }
        }
        .onAppear { onDemand.loadShelf(kind, categoryID: category.id) }
    }

    private func seeAll(_ titles: [OnDemandTitle]?) -> (() -> Void)? {
        guard let titles, !titles.isEmpty else { return nil }
        return { navigate(.category(kind, category)) }
    }

    @ViewBuilder
    private func row(titles: [OnDemandTitle]?, load: OnDemandLibrary.Load?) -> some View {
        if let titles, !titles.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: OnDemandMetrics.cardSpacing) {
                    ForEach(titles.prefix(shelfLimit)) { title in
                        OnDemandPressable(action: { navigate(.title(title)) }) {
                            OnDemandPosterCard(title: title)
                        }
                    }
                    #if os(tvOS)
                    OnDemandPressable(action: { navigate(.category(kind, category)) }) {
                        OnDemandSeeAllCard(count: titles.count)
                    }
                    #endif
                }
                .padding(.horizontal, OnDemandMetrics.gutter)
                .padding(.vertical, OnDemandMetrics.liftRoom)
            }
            .scrollClipDisabled()
            #if os(tvOS)
            .focusSection()
            #endif
        } else if load == .failed {
            OnDemandPressable(scale: LineupStyle.controlLift,
                              action: { onDemand.loadShelf(kind, categoryID: category.id, force: true) }) {
                Label("Couldn't load this category. Try again", systemImage: "arrow.clockwise")
                    .font(.inter(.callout, .semibold))
                    .foregroundStyle(LineupStyle.lightPurple)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(LineupStyle.surface, in: Capsule())
            }
            .padding(.horizontal, OnDemandMetrics.gutter)
        } else {
            OnDemandPlaceholderRow()
        }
    }
}

private struct OnDemandPlaceholderRow: View {
    var body: some View {
        HStack(spacing: OnDemandMetrics.cardSpacing) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: OnDemandMetrics.cardRadius, style: .continuous)
                        .fill(LineupStyle.surface)
                        .frame(width: OnDemandMetrics.posterWidth,
                               height: OnDemandMetrics.posterWidth * 1.5)
                    RoundedRectangle(cornerRadius: 4).fill(LineupStyle.surface)
                        .frame(width: OnDemandMetrics.posterWidth * 0.7, height: 12)
                }
            }
        }
        .padding(.horizontal, OnDemandMetrics.gutter)
        .padding(.vertical, OnDemandMetrics.liftRoom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Cards

private struct OnDemandArt: View {
    let url: String?
    let ratio: CGFloat
    var symbol = "film"
    var drawnWidth: CGFloat = OnDemandMetrics.posterWidth

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                ZStack {
                    LinearGradient(colors: [LineupStyle.raised, LineupStyle.surface],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    LineupArtView(url: url.flatMap(URL.init(string:)), width: drawnWidth) { loaded in
                        if let image = loaded {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: symbol).font(.system(size: drawnWidth / 6, weight: .light))
                                .foregroundStyle(LineupStyle.lightPurple.opacity(0.4))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: OnDemandMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OnDemandMetrics.cardRadius, style: .continuous)
                .stroke(LineupStyle.line, lineWidth: 1))
    }
}

private struct OnDemandProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.55))
                Capsule().fill(LineupStyle.highlight)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: OnDemandMetrics.progressHeight)
    }
}

private struct OnDemandWatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: OnDemandMetrics.badgeSize * 0.45, weight: .heavy))
            .foregroundStyle(LineupStyle.background)
            .frame(width: OnDemandMetrics.badgeSize, height: OnDemandMetrics.badgeSize)
            .background(LineupStyle.lightPurple, in: Circle())
            .accessibilityLabel("Watched")
    }
}

private struct OnDemandPosterCard: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    let title: OnDemandTitle
    var width: CGFloat? = OnDemandMetrics.posterWidth

    var body: some View {
        let record = title.kind == .movies ? onDemand.record(.movie, title.providerID) : nil
        VStack(alignment: .leading, spacing: 8) {
            OnDemandArt(url: title.artwork, ratio: 2 / 3, symbol: title.kind == .movies ? "film" : "tv",
                        drawnWidth: OnDemandMetrics.posterWidth)
                .overlay(alignment: .topTrailing) {
                    if record?.completed == true { OnDemandWatchedBadge().padding(8) }
                }
                .overlay(alignment: .bottom) {
                    if let record, OnDemandProgressPolicy.resumePosition(record) != nil {
                        OnDemandProgressBar(fraction: record.fraction).padding(8)
                    }
                }
            Text(title.name).font(OnDemandMetrics.cardTitleFont)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(LineupStyle.text)
            Text(meta).font(.inter(.caption2, .medium)).lineLimit(1)
                .foregroundStyle(LineupStyle.secondary)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts: [String] = []
        if let year = title.year { parts.append(String(year)) }
        if let rating = title.formattedRating { parts.append("★ " + rating) }
        return parts.isEmpty ? (title.kind == .movies ? "Movie" : "Series") : parts.joined(separator: "  ·  ")
    }
}

private struct OnDemandSeeAllCard: View {
    let count: Int

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2").font(.system(size: 30, weight: .light))
            Text("See All").font(OnDemandMetrics.cardTitleFont)
            Text("\(count) titles").font(.inter(.caption2, .medium)).opacity(0.6)
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .frame(width: OnDemandMetrics.posterWidth, height: OnDemandMetrics.posterWidth * 1.5)
        .background(LineupStyle.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: OnDemandMetrics.cardRadius, style: .continuous))
    }
}

private struct OnDemandContinueCard: View {
    let record: OnDemandPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OnDemandArt(url: record.still ?? record.artwork, ratio: 16 / 9,
                        symbol: record.kind == .movie ? "film" : "tv",
                        drawnWidth: OnDemandMetrics.landscapeWidth)
                .overlay(alignment: .bottom) {
                    if !record.isUpNext { OnDemandProgressBar(fraction: record.fraction).padding(10) }
                }
                .overlay(alignment: .topLeading) {
                    if record.isUpNext {
                        Text("UP NEXT").font(.inter(.caption2, .bold)).tracking(1)
                            .foregroundStyle(LineupStyle.background)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(LineupStyle.highlight, in: Capsule())
                            .padding(10)
                    }
                }
            Text(record.displayName).font(OnDemandMetrics.cardTitleFont).lineLimit(1)
                .foregroundStyle(LineupStyle.text)
            Text(detail).font(.inter(.caption, .medium)).lineLimit(1)
                .foregroundStyle(LineupStyle.secondary)
        }
        .frame(width: OnDemandMetrics.landscapeWidth)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let code = record.episodeCode { parts.append(code) }
        if record.seriesName != nil { parts.append(record.title) }
        if !record.isUpNext, record.duration > record.position {
            let left = Int(record.duration - record.position)
            parts.append((OnDemandNaming.runtime(left) ?? "<1m") + " left")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Category

private enum OnDemandSort: String, CaseIterable, Identifiable {
    case provider = "Featured"
    case added = "Recently Added"
    case name = "A–Z"
    case rating = "Top Rated"

    var id: String { rawValue }

    func apply(_ titles: [OnDemandTitle]) -> [OnDemandTitle] {
        switch self {
        case .provider: return titles
        case .added: return titles.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        case .name: return titles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .rating: return titles.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
    }
}

private struct OnDemandCategoryScreen: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    @Environment(\.onDemandOpen) private var navigate
    let kind: OnDemandKind
    let category: OnDemandCategory
    @State private var sort = OnDemandSort.provider

    var body: some View {
        let titles = sort.apply(onDemand.titles(kind, in: category.id) ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: OnDemandMetrics.headerSpacing) {
                #if os(tvOS)
                Text(category.name).font(OnDemandMetrics.pageTitleFont)
                    .foregroundStyle(LineupStyle.text)
                #endif
                HStack(spacing: 12) {
                    ForEach(OnDemandSort.allCases) { option in
                        OnDemandPill(title: option.rawValue, selected: option == sort) { sort = option }
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
                OnDemandGrid(titles: titles)
            }
            .padding(.horizontal, OnDemandMetrics.gutter)
            .padding(.top, OnDemandMetrics.headerTop)
            .padding(.bottom, OnDemandMetrics.gutter)
        }
        .scrollClipDisabled()
        .background(OnDemandBackdrop().ignoresSafeArea())
        .onAppear { onDemand.loadShelf(kind, categoryID: category.id) }
        #if !os(tvOS)
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct OnDemandGrid: View {
    @Environment(\.onDemandOpen) private var navigate
    let titles: [OnDemandTitle]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: OnDemandMetrics.gridMinimum),
                                     spacing: OnDemandMetrics.cardSpacing, alignment: .top)],
                  alignment: .leading, spacing: OnDemandMetrics.gridRowSpacing) {
            ForEach(titles) { title in
                OnDemandPressable(action: { navigate(.title(title)) }) {
                    OnDemandPosterCard(title: title, width: nil)
                }
            }
        }
    }
}

// MARK: - Search

private struct OnDemandSearchScreen: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    @State private var kind: OnDemandKind
    @State private var query = ""
    @State private var results: [OnDemandTitle] = []

    init(kind: OnDemandKind) {
        _kind = State(initialValue: kind)
    }

    var body: some View {
        let load = onDemand.searchLoads[kind]
        ScrollView {
            VStack(alignment: .leading, spacing: OnDemandMetrics.headerSpacing) {
                HStack(spacing: 12) {
                    ForEach(OnDemandKind.allCases) { option in
                        OnDemandPill(title: option.title, selected: option == kind) { kind = option }
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
                if load == .loading && results.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading every \(kind == .movies ? "movie" : "series")… the first search takes a moment.")
                            .font(.inter(.callout))
                    }
                    .foregroundStyle(LineupStyle.secondary)
                } else if load == .failed {
                    Text("The provider didn't send its catalogue. Try again in a moment.")
                        .font(.inter(.callout)).foregroundStyle(LineupStyle.secondary)
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Search this provider's \(kind.title.lowercased()) by title.")
                        .font(.inter(.callout)).foregroundStyle(LineupStyle.secondary)
                } else if results.isEmpty {
                    Text("No \(kind.title.lowercased()) match “\(query)”.")
                        .font(.inter(.callout)).foregroundStyle(LineupStyle.secondary)
                } else {
                    OnDemandGrid(titles: results)
                }
            }
            .padding(.horizontal, OnDemandMetrics.gutter)
            .padding(.top, OnDemandMetrics.headerTop)
            .padding(.bottom, OnDemandMetrics.gutter)
        }
        .scrollClipDisabled()
        .background(OnDemandBackdrop().ignoresSafeArea())
        .searchable(text: $query, prompt: prompt)
        #if !os(tvOS)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { onDemand.loadSearchIndex(kind) }
        .onChange(of: kind) { _, value in onDemand.loadSearchIndex(value) }
        // Re-run when the catalogue arrives as well as on every keystroke, so
        // a query typed while it loaded is answered once it has.
        .task(id: SearchInput(kind: kind, query: query, load: load)) {
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            results = onDemand.search(kind, query)
        }
    }

    private var prompt: String { kind == .movies ? "Search movies" : "Search series" }

    private struct SearchInput: Equatable {
        let kind: OnDemandKind
        let query: String
        let load: OnDemandLibrary.Load?
    }
}

// MARK: - Detail

private struct OnDemandDetailScreen: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    @Environment(\.onDemandPlay) private var play
    let title: OnDemandTitle
    @State private var movie: OnDemandMovieDetail?
    @State private var series: OnDemandSeriesDetail?
    @State private var failure: String?
    @State private var loading = true
    @State private var season: Int?

    private var facts: OnDemandFacts? { movie?.facts ?? series?.facts }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OnDemandMetrics.sectionSpacing) {
                hero
                if let series, !series.seasons.isEmpty {
                    OnDemandSeasonBrowser(title: title, detail: series, season: $season)
                }
                credits
            }
            .padding(.bottom, OnDemandMetrics.gutter)
        }
        .scrollClipDisabled()
        .background(OnDemandHeroBackdrop(url: backdropURL).ignoresSafeArea())
        #if !os(tvOS)
        .navigationTitle(title.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task(id: title.id) { await load() }
    }

    private var backdropURL: String? {
        facts?.backdrops.first ?? facts?.poster ?? title.artwork
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: OnDemandMetrics.heroSpacing) {
            #if os(tvOS)
            OnDemandArt(url: title.artwork ?? facts?.poster, ratio: 2 / 3,
                        symbol: title.kind == .movies ? "film" : "tv",
                        drawnWidth: OnDemandMetrics.heroPosterWidth)
                .frame(width: OnDemandMetrics.heroPosterWidth)
                .lineupShadow(.lifted)
            #endif
            VStack(alignment: .leading, spacing: OnDemandMetrics.heroTextSpacing) {
                Text(title.name).font(OnDemandMetrics.detailTitleFont)
                    .foregroundStyle(LineupStyle.text)
                    .lineLimit(3).minimumScaleFactor(0.7)
                if !metaLine.isEmpty {
                    Text(metaLine).font(.inter(.callout, .semibold))
                        .foregroundStyle(LineupStyle.secondary)
                }
                if let plot = facts?.plot {
                    Text(plot).font(OnDemandMetrics.plotFont)
                        .foregroundStyle(LineupStyle.text.opacity(0.86))
                        .lineLimit(OnDemandMetrics.plotLines)
                        .frame(maxWidth: OnDemandMetrics.plotWidth, alignment: .leading)
                }
                actions.padding(.top, 6)
                if loading && facts == nil {
                    ProgressView().padding(.top, 4)
                } else if let failure {
                    Text(failure).font(.inter(.callout)).foregroundStyle(LineupStyle.warning)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnDemandMetrics.gutter)
        .padding(.top, OnDemandMetrics.heroTop)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = facts?.year ?? title.year { parts.append(String(year)) }
        if let runtime = facts?.formattedRuntime, title.kind == .movies { parts.append(runtime) }
        if let series {
            let count = series.seasons.filter { !$0.isSpecials }.count
            if count > 0 { parts.append(count == 1 ? "1 Season" : "\(count) Seasons") }
        }
        if let genre = facts?.genre { parts.append(genre) }
        if let rating = (facts?.rating ?? title.rating).flatMap({ $0 > 0 ? $0 : nil }) {
            parts.append("★ " + String(format: "%.1f", rating))
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 14) {
            if title.kind == .movies {
                let resume = onDemand.resumePosition(.movie, title.providerID)
                let record = onDemand.record(.movie, title.providerID)
                OnDemandActionButton(title: resume == nil ? "Play" : "Resume",
                                     detail: resumeDetail(record),
                                     systemImage: "play.fill", prominent: true, initialFocus: true) {
                    play(onDemand.playRequest(for: title, detail: movie))
                }
                if resume != nil {
                    OnDemandActionButton(title: "Start Over", systemImage: "gobackward") {
                        play(onDemand.playRequest(for: title, detail: movie, fromStart: true))
                    }
                }
                let watched = record?.completed == true
                OnDemandActionButton(title: watched ? "Watched" : "Mark Watched",
                                     systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle") {
                    onDemand.setWatched(!watched, .movie(title, detail: movie), upNext: nil)
                }
            } else if let series,
                      let start = OnDemandProgressPolicy.startingEpisode(in: series.seasons,
                                                                        records: onDemand.playbacks) {
                OnDemandActionButton(title: (start.resume == nil ? "Play " : "Resume ") + start.episode.code,
                                     detail: start.episode.title,
                                     systemImage: "play.fill", prominent: true, initialFocus: true) {
                    play(onDemand.playRequest(for: start.episode, of: title, detail: series))
                }
                if start.resume != nil {
                    OnDemandActionButton(title: "Start Over", systemImage: "gobackward") {
                        play(onDemand.playRequest(for: start.episode, of: title, detail: series, fromStart: true))
                    }
                }
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func resumeDetail(_ record: OnDemandPlayback?) -> String? {
        guard let record, OnDemandProgressPolicy.resumePosition(record) != nil else { return nil }
        let left = Int(max(0, record.duration - record.position))
        return (OnDemandNaming.runtime(left) ?? "<1m") + " left"
    }

    @ViewBuilder
    private var credits: some View {
        let rows = creditRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label.uppercased()).font(.inter(.caption2, .bold)).tracking(1.2)
                            .foregroundStyle(LineupStyle.secondary)
                            .frame(width: OnDemandMetrics.creditLabelWidth, alignment: .leading)
                        Text(row.value).font(.inter(.callout)).lineLimit(3)
                            .foregroundStyle(LineupStyle.text.opacity(0.86))
                    }
                }
            }
            .padding(.horizontal, OnDemandMetrics.gutter)
            .frame(maxWidth: OnDemandMetrics.plotWidth + OnDemandMetrics.gutter * 2, alignment: .leading)
            #if os(tvOS)
            // Text alone cannot take focus, so without an anchor the remote
            // could never scroll far enough to read the credits.
            .focusable()
            #endif
        }
    }

    private struct Credit: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var creditRows: [Credit] {
        var rows: [Credit] = []
        if let director = facts?.director { rows.append(Credit(label: "Director", value: director)) }
        if let cast = facts?.cast { rows.append(Credit(label: "Cast", value: cast)) }
        return rows
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            if title.kind == .movies {
                movie = try await onDemand.movieDetail(title)
            } else {
                let detail = try await onDemand.seriesDetail(title)
                series = detail
                if season == nil {
                    season = OnDemandProgressPolicy.startingEpisode(in: detail.seasons,
                                                                   records: onDemand.playbacks)?.episode.season
                        ?? detail.seasons.first?.number
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // A film still plays without its details; a series cannot be
            // played without its episode list.
            failure = title.kind == .movies
                ? "Details aren't available, but the movie can still be played."
                : "Couldn't load the episodes. " + error.localizedDescription
        }
        loading = false
    }
}

private struct OnDemandSeasonBrowser: View {
    @EnvironmentObject private var onDemand: OnDemandLibrary
    @Environment(\.onDemandPlay) private var play
    let title: OnDemandTitle
    let detail: OnDemandSeriesDetail
    @Binding var season: Int?

    var body: some View {
        let current = detail.seasons.first { $0.number == season } ?? detail.seasons[0]
        VStack(alignment: .leading, spacing: OnDemandMetrics.shelfHeadingSpacing) {
            if detail.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(detail.seasons) { option in
                            OnDemandPill(title: option.name, selected: option.number == current.number) {
                                season = option.number
                            }
                        }
                    }
                    .padding(.horizontal, OnDemandMetrics.gutter)
                    .padding(.vertical, OnDemandMetrics.liftRoom / 2)
                }
                .scrollClipDisabled()
                #if os(tvOS)
                .focusSection()
                #endif
            } else {
                OnDemandShelfHeading(title: current.name, detail: "\(current.episodes.count) episodes")
            }
            #if os(tvOS)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: OnDemandMetrics.cardSpacing) {
                    ForEach(current.episodes) { episode in episodeButton(episode) }
                }
                .padding(.horizontal, OnDemandMetrics.gutter)
                .padding(.vertical, OnDemandMetrics.liftRoom)
            }
            .scrollClipDisabled()
            .focusSection()
            #else
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(current.episodes) { episode in episodeButton(episode) }
            }
            .padding(.horizontal, OnDemandMetrics.gutter)
            #endif
        }
    }

    private func episodeButton(_ episode: OnDemandEpisode) -> some View {
        let record = onDemand.record(.episode, episode.id)
        return OnDemandPressable(action: {
            play(onDemand.playRequest(for: episode, of: title, detail: detail))
        }) {
            OnDemandEpisodeCard(episode: episode, record: record)
        }
        .contextMenu {
            let watched = record?.completed == true
            Button(watched ? "Mark as Unwatched" : "Mark as Watched",
                   systemImage: watched ? "eye.slash" : "checkmark.circle") {
                let next = OnDemandProgressPolicy.nextEpisode(after: episode.id, in: detail.seasons) {
                    $0 != episode.id && onDemand.isWatched(.episode, $0)
                }
                onDemand.setWatched(!watched, .episode(episode, of: title, detail: detail),
                                    upNext: next.map { OnDemandPlayback.episode($0, of: title, detail: detail) })
            }
            if OnDemandProgressPolicy.resumePosition(record) != nil {
                Button("Play from Beginning", systemImage: "gobackward") {
                    play(onDemand.playRequest(for: episode, of: title, detail: detail, fromStart: true))
                }
            }
        }
    }
}

private struct OnDemandEpisodeCard: View {
    let episode: OnDemandEpisode
    let record: OnDemandPlayback?

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 8) {
            still.frame(width: OnDemandMetrics.episodeWidth)
            text.frame(width: OnDemandMetrics.episodeWidth, alignment: .leading)
        }
        #else
        HStack(alignment: .top, spacing: 14) {
            still.frame(width: OnDemandMetrics.episodeWidth)
            text
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        #endif
    }

    private var still: some View {
        OnDemandArt(url: episode.still, ratio: 16 / 9, symbol: "tv", drawnWidth: OnDemandMetrics.episodeWidth)
            .overlay(alignment: .topTrailing) {
                if record?.completed == true { OnDemandWatchedBadge().padding(6) }
            }
            .overlay(alignment: .bottom) {
                if let record, OnDemandProgressPolicy.resumePosition(record) != nil {
                    OnDemandProgressBar(fraction: record.fraction).padding(6)
                }
            }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(episode.number). \(episode.title)").font(OnDemandMetrics.cardTitleFont)
                .lineLimit(2).foregroundStyle(LineupStyle.text)
            if let runtime = episode.formattedRuntime {
                Text(runtime).font(.inter(.caption, .medium)).foregroundStyle(LineupStyle.secondary)
            }
            if let plot = episode.plot {
                Text(plot).font(.inter(.caption)).lineLimit(3)
                    .foregroundStyle(LineupStyle.text.opacity(0.7))
            }
        }
        .multilineTextAlignment(.leading)
    }
}

// MARK: - Controls and chrome

/// A card or control that takes a press: TVSelectable's own focus look on the
/// television, a plain button on the phone.
private struct OnDemandPressable<Content: View>: View {
    var scale: CGFloat = LineupStyle.cardLift
    var initialFocus = false
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        #if os(tvOS)
        TVSelectable(scale: scale, action: action, requestInitialFocus: initialFocus) { content }
        #else
        Button(action: action) { content }.lineupFlatButton()
        #endif
    }
}

private struct OnDemandPill: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        OnDemandPressable(scale: LineupStyle.controlLift, action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(OnDemandMetrics.pillFont)
            .foregroundStyle(selected ? LineupStyle.background : LineupStyle.lightPurple)
            .padding(.horizontal, OnDemandMetrics.pillPadding)
            .frame(minHeight: OnDemandMetrics.pillHeight)
            .background(selected ? LineupStyle.lightPurple : LineupStyle.surface, in: Capsule())
            .overlay(Capsule().stroke(LineupStyle.line, lineWidth: selected ? 0 : 1))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OnDemandActionButton: View {
    let title: String
    var detail: String?
    let systemImage: String
    var prominent = false
    var initialFocus = false
    let action: () -> Void

    var body: some View {
        OnDemandPressable(scale: LineupStyle.controlLift, initialFocus: initialFocus, action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let detail {
                        Text(detail).font(.inter(.caption2, .medium)).lineLimit(1).opacity(0.75)
                    }
                }
            }
            .font(OnDemandMetrics.actionFont)
            .foregroundStyle(prominent ? LineupStyle.background : LineupStyle.lightPurple)
            .padding(.horizontal, OnDemandMetrics.actionPadding)
            .frame(minHeight: OnDemandMetrics.actionHeight)
            .frame(maxWidth: prominent ? OnDemandMetrics.primaryActionWidth : nil)
            .background(prominent ? LineupStyle.lightPurple : LineupStyle.surface,
                        in: RoundedRectangle(cornerRadius: OnDemandMetrics.actionRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OnDemandMetrics.actionRadius, style: .continuous)
                .stroke(LineupStyle.line, lineWidth: prominent ? 0 : 1))
        }
    }
}

private struct OnDemandMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 42, weight: .light))
            Text(title).font(.inter(.title2, .semibold)).foregroundStyle(LineupStyle.text)
            Text(detail).font(.inter(.callout)).multilineTextAlignment(.center).opacity(0.72)
                .frame(maxWidth: 520)
            if let actionTitle, let action {
                OnDemandActionButton(title: actionTitle, systemImage: "arrow.clockwise",
                                     prominent: true, initialFocus: true, action: action)
                    .padding(.top, 6)
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnDemandBackdrop: View {
    var body: some View {
        ZStack {
            LineupStyle.background
            RadialGradient(colors: [LineupStyle.lightPurple.opacity(0.055), .clear],
                           center: .topTrailing, startRadius: 30, endRadius: 760)
        }
    }
}

/// The title's own art behind its page, faded into the app's background so the
/// text over it stays readable whatever the picture is.
private struct OnDemandHeroBackdrop: View {
    let url: String?

    var body: some View {
        ZStack(alignment: .top) {
            LineupStyle.background
            LineupArtView(url: url.flatMap(URL.init(string:)), width: OnDemandMetrics.backdropWidth) { loaded in
                if let image = loaded {
                    image.resizable().scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: OnDemandMetrics.backdropHeight)
                        .clipped()
                        .opacity(0.55)
                }
            }
            .frame(height: OnDemandMetrics.backdropHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            LinearGradient(colors: [LineupStyle.background.opacity(0.2), LineupStyle.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: OnDemandMetrics.backdropHeight)
            #if os(tvOS)
            LinearGradient(colors: [LineupStyle.background.opacity(0.92), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: OnDemandMetrics.backdropHeight)
            #endif
        }
    }
}

private enum OnDemandMetrics {
    #if os(tvOS)
    static let gutter: CGFloat = 80
    static let headerTop: CGFloat = 30
    static let headerSpacing: CGFloat = 22
    static let sectionSpacing: CGFloat = 34
    static let shelfHeadingSpacing: CGFloat = 6
    static let cardSpacing: CGFloat = 36
    static let liftRoom: CGFloat = 22
    static let posterWidth: CGFloat = 220
    static let landscapeWidth: CGFloat = 400
    static let episodeWidth: CGFloat = 380
    static let gridMinimum: CGFloat = 210
    static let gridRowSpacing: CGFloat = 44
    static let cardRadius: CGFloat = 16
    static let progressHeight: CGFloat = 6
    static let badgeSize: CGFloat = 28
    static let heroTop: CGFloat = 60
    static let heroSpacing: CGFloat = 48
    static let heroTextSpacing: CGFloat = 16
    static let heroPosterWidth: CGFloat = 300
    static let plotWidth: CGFloat = 1000
    static let plotLines = 5
    static let creditLabelWidth: CGFloat = 120
    static let backdropWidth: CGFloat = 1920
    static let backdropHeight: CGFloat = 900
    static let pillHeight: CGFloat = 50
    static let pillPadding: CGFloat = 24
    static let actionHeight: CGFloat = 66
    static let actionPadding: CGFloat = 28
    static let actionRadius: CGFloat = 14
    static let primaryActionWidth: CGFloat = 420
    static let pageTitleFont = Font.inter(44, .bold)
    static let shelfTitleFont = Font.inter(26, .semibold)
    static let cardTitleFont = Font.inter(20, .semibold)
    static let detailTitleFont = Font.inter(58, .bold)
    static let plotFont = Font.inter(22)
    static let pillFont = Font.inter(19, .semibold)
    static let actionFont = Font.inter(21, .semibold)
    #else
    static let gutter: CGFloat = 20
    static let headerTop: CGFloat = 12
    static let headerSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 22
    static let shelfHeadingSpacing: CGFloat = 4
    static let cardSpacing: CGFloat = 12
    static let liftRoom: CGFloat = 6
    static let posterWidth: CGFloat = 116
    static let landscapeWidth: CGFloat = 250
    static let episodeWidth: CGFloat = 140
    static let gridMinimum: CGFloat = 104
    static let gridRowSpacing: CGFloat = 20
    static let cardRadius: CGFloat = 10
    static let progressHeight: CGFloat = 4
    static let badgeSize: CGFloat = 22
    static let heroTop: CGFloat = 170
    static let heroSpacing: CGFloat = 0
    static let heroTextSpacing: CGFloat = 12
    static let heroPosterWidth: CGFloat = 0
    static let plotWidth: CGFloat = 640
    static let plotLines = 6
    static let creditLabelWidth: CGFloat = 70
    static let backdropWidth: CGFloat = 430
    static let backdropHeight: CGFloat = 340
    static let pillHeight: CGFloat = 34
    static let pillPadding: CGFloat = 16
    static let actionHeight: CGFloat = 48
    static let actionPadding: CGFloat = 18
    static let actionRadius: CGFloat = 12
    static let primaryActionWidth: CGFloat = .infinity
    static let pageTitleFont = Font.inter(30, .bold)
    static let shelfTitleFont = Font.inter(18, .semibold)
    static let cardTitleFont = Font.inter(.footnote, .semibold)
    static let detailTitleFont = Font.inter(30, .bold)
    static let plotFont = Font.inter(.subheadline)
    static let pillFont = Font.inter(.subheadline, .semibold)
    static let actionFont = Font.inter(.callout, .semibold)
    #endif
}
