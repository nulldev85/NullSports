import SwiftUI

// MARK: - The Search tab

/// One search across the whole app: films and shows on the media servers,
/// live channels, the TV guide and the games, and the IPTV provider's VOD --
/// sorted into Movies, Shows, Live TV and VOD, each result saying where in
/// the app it lives. Typing "training day" says whether it is a film on a
/// server, a channel to tune to, a showing in the guide on Thursday, or a
/// copy on the provider's VOD shelves.
struct AppSearchView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var media: MediaLibrary
    #if !os(tvOS)
    /// Plays a channel full screen. On the phone the player belongs to the
    /// view that owns the tabs.
    let play: (XtreamStream) -> Void
    #endif
    @State private var query = ""
    /// The query the results on screen are for, which trails the typing.
    @State private var searchedTerm = ""
    @State private var results = AppSearchResults()
    /// The chosen chip; nil is All.
    @State private var category: AppSearchCategory?
    @State private var searchingServers = false
    @State private var serverProblem: String?
    @State private var pushed: MediaItem?
    /// Something that is not on yet, asked about before anything is tuned.
    @State private var choice: AppSearchHit?
    #if os(tvOS)
    @State private var playback: AppSearchPlayback?
    #endif

    private typealias Metrics = AppSearchMetrics

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Metrics.bottomInset)
            }
            .background(LineupStyle.background.ignoresSafeArea())
            .foregroundStyle(LineupStyle.text)
            // As the Library registers them, so a page opened from here can
            // open the pages under it.
            .navigationDestination(for: MediaItem.self) { item in MediaBrowseDestination(item: item) }
            .navigationDestination(item: $pushed) { item in MediaBrowseDestination(item: item) }
            #if os(tvOS)
            .searchable(text: $query, prompt: "Movies, shows, channels, games")
            #else
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Movies, shows, channels, games")
            #endif
        }
        .task(id: query) { await search(query) }
        .confirmationDialog(choice.map(choiceTitle) ?? "", isPresented: Binding(
            get: { choice != nil }, set: { if !$0 { choice = nil } }
        ), titleVisibility: .visible, presenting: choice) { hit in
            if let station = channel(of: hit) {
                Button("Watch \(station.name) Now") { tune(station, game: game(of: hit)) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { hit in
            Text(choiceMessage(hit))
        }
        #if os(tvOS)
        .fullScreenCover(item: $playback) { playback in
            PlayerView(urls: library.playbackURLs(for: playback.channel),
                       title: playback.channel.name,
                       program: library.guidePrograms(for: playback.channel).normalizedEPG().first { $0.isLive },
                       game: playback.game,
                       channelID: playback.channel.id)
        }
        #endif
    }

    // MARK: Searching

    /// The live side and the provider's VOD answer from what is already on the
    /// device, so they are listed at once; the media servers are asked over
    /// the network, and their films and shows join when they answer.
    private func search(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            searchedTerm = ""
            results = AppSearchResults()
            searchingServers = false
            serverProblem = nil
            return
        }
        // Each letter typed restarts this; only a pause searches.
        do { try await Task.sleep(for: .milliseconds(320)) } catch { return }
        let snapshot = liveSnapshot()
        let live = await Task.detached(priority: .userInitiated) { AppSearch.live(term, in: snapshot) }.value
        guard !Task.isCancelled else { return }
        let vod = await media.searchProviderVOD(term).map { found in
            AppSearchHit(id: "vod|" + found.item.id, kind: .vod(found.item, group: found.group))
        }
        guard !Task.isCancelled else { return }
        var next = AppSearchResults()
        next.live = live
        next.vod = vod
        if term == searchedTerm {
            // The same search again keeps the films and shows it found.
            next.movies = results.movies
            next.shows = results.shows
        }
        results = next
        searchedTerm = term
        searchingServers = !media.profiles.isEmpty
        serverProblem = nil
        guard searchingServers else { return }
        let servers = await media.searchServers(term)
        guard !Task.isCancelled else { return }
        let titles = AppSearch.titles(from: servers.groups)
        results.movies = titles.filter { $0.category == .movies }
        results.shows = titles.filter { $0.category == .shows }
        searchingServers = false
        if titles.isEmpty, let error = servers.error, !MediaLibrary.isCancellation(error) {
            serverProblem = error.localizedDescription
        }
    }

    private func liveSnapshot() -> AppSearch.LiveSnapshot {
        let groups = Dictionary(library.categories.map { ($0.categoryID, $0.categoryName) },
                                uniquingKeysWith: { first, _ in first })
        let games = library.games(for: nil).map { (game: $0, channel: library.stream(for: $0)) }
        return AppSearch.LiveSnapshot(channels: library.streams, groups: groups,
                                      programs: library.programsByChannel, games: games)
    }

    // MARK: Choosing

    private func open(_ hit: AppSearchHit) {
        switch hit.kind {
        case .title(let item, _), .vod(let item, _):
            pushed = item
        case .channel(let channel, _, _):
            tune(channel, game: nil)
        case .airing(let program, let channel, _, _):
            if program.isLive { tune(channel, game: nil) } else { choice = hit }
        case .game(let game, let channel):
            if game.isLive, let channel { tune(channel, game: game) } else { choice = hit }
        }
    }

    private func tune(_ channel: XtreamStream, game: SportsGame?) {
        choice = nil
        #if os(tvOS)
        playback = AppSearchPlayback(channel: channel, game: game)
        #else
        play(channel)
        #endif
    }

    private func channel(of hit: AppSearchHit) -> XtreamStream? {
        switch hit.kind {
        case .airing(_, let channel, _, _): channel
        case .game(_, let channel): channel
        case .channel(let channel, _, _): channel
        case .title, .vod: nil
        }
    }

    private func game(of hit: AppSearchHit) -> SportsGame? {
        if case .game(let game, _) = hit.kind { return game }
        return nil
    }

    private func choiceTitle(_ hit: AppSearchHit) -> String {
        switch hit.kind {
        case .airing(let program, _, _, _): program.title
        case .game(let game, _): AppSearchFormat.matchup(game)
        default: ""
        }
    }

    private func choiceMessage(_ hit: AppSearchHit) -> String {
        switch hit.kind {
        case .airing(let program, let channel, _, _):
            let time = program.start.formatted(date: .omitted, time: .shortened)
            return "Starts \(AppSearchFormat.day(program.start)) at \(time) on \(channel.name). Watch the channel now?"
        case .game(let game, let channel):
            guard let channel else {
                return "No channel has been matched to this game yet. It will be on the Live tab once one is."
            }
            let time = game.start.formatted(date: .omitted, time: .shortened)
            return "Starts \(AppSearchFormat.day(game.start)) at \(time) on \(channel.name). Watch the channel now?"
        default:
            return ""
        }
    }

    // MARK: Layout

    @ViewBuilder
    private var content: some View {
        if searchedTerm.isEmpty {
            AppSearchPrompt(searching: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                chips
                if let category {
                    categoryBody(category)
                } else {
                    allBody
                }
            }
            .padding(.top, Metrics.topInset)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.chipGap) {
                chip(nil, title: "All", count: results.total, waiting: searchingServers && results.total == 0)
                ForEach(AppSearchCategory.allCases) { kind in
                    chip(kind, title: kind.title, count: results.hits(in: kind).count,
                         waiting: searchingServers && (kind == .movies || kind == .shows))
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.chipLift)
        }
        .scrollClipDisabled()
        .lineupFocusRegion()
    }

    @ViewBuilder
    private func chip(_ kind: AppSearchCategory?, title: String, count: Int, waiting: Bool) -> some View {
        let label = AppSearchChip(title: title, count: count, waiting: waiting, active: category == kind)
        #if os(tvOS)
        TVSelectable(scale: LineupStyle.controlLift, fillRadius: Metrics.chipHeight / 2,
                     drawsFocusChrome: false, action: { category = kind }) { label }
        #else
        Button { withAnimation(.easeOut(duration: 0.18)) { category = kind } } label: { label }
            .lineupFlatButton()
        #endif
    }

    @ViewBuilder
    private var allBody: some View {
        ForEach(AppSearchCategory.allCases) { kind in
            let hits = results.hits(in: kind)
            if !hits.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.headerGap) {
                    sectionHeader(kind.title, count: hits.count, seeAll: kind)
                    switch kind {
                    case .movies, .shows, .vod: posterShelf(hits)
                    case .live: liveList(Array(hits.prefix(Metrics.liveInAll)))
                    }
                }
            }
        }
        if searchingServers {
            AppSearchWaiting(text: "Searching " + serverNames + "…")
                .padding(.horizontal, Metrics.inset)
        } else if results.total == 0 {
            AppSearchEmpty(title: "No results for “\(searchedTerm)”",
                           detail: serverProblem.map { "Your servers didn’t answer: " + $0 }
                               ?? "Nothing in your library, live TV, guide or VOD matched it.")
        } else if let serverProblem {
            Text("Your servers didn’t answer, so movies and shows may be missing: " + serverProblem)
                .font(.inter(Metrics.placeSize))
                .foregroundStyle(LineupStyle.secondary)
                .padding(.horizontal, Metrics.inset)
        }
    }

    @ViewBuilder
    private func categoryBody(_ kind: AppSearchCategory) -> some View {
        let hits = results.hits(in: kind)
        if hits.isEmpty {
            if searchingServers && (kind == .movies || kind == .shows) {
                AppSearchWaiting(text: "Searching " + serverNames + "…")
                    .padding(.horizontal, Metrics.inset)
            } else {
                AppSearchEmpty(title: "No \(kind.title.lowercased()) for “\(searchedTerm)”",
                               detail: emptyDetail(kind))
            }
        } else {
            switch kind {
            case .movies, .shows, .vod:
                posterGrid(hits)
            case .live:
                liveSections(hits)
            }
        }
    }

    private func emptyDetail(_ kind: AppSearchCategory) -> String {
        switch kind {
        case .movies, .shows: serverProblem.map { "Your servers didn’t answer: " + $0 }
            ?? "None of your servers has one by that name."
        case .live: "No channel, game or listing in the guide matched it."
        case .vod: "Your provider’s VOD has nothing by that name."
        }
    }

    private var serverNames: String {
        let names = media.profiles.map(\.name)
        return names.isEmpty ? "your servers" : ListFormatter.localizedString(byJoining: names)
    }

    private func sectionHeader(_ title: String, count: Int, seeAll kind: AppSearchCategory?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title.uppercased())
                .font(.inter(Metrics.headerSize, .heavy)).tracking(Metrics.headerTracking)
            Text("\(count)")
                .font(.interDigits(Metrics.headerSize, .heavy))
                .opacity(0.6)
            Spacer(minLength: 12)
            if let kind {
                #if os(tvOS)
                TVSelectable(scale: LineupStyle.controlLift, action: { category = kind }) {
                    AppSearchSeeAll()
                }
                #else
                Button { withAnimation(.easeOut(duration: 0.18)) { category = kind } } label: { AppSearchSeeAll() }
                    .lineupFlatButton()
                #endif
            }
        }
        .foregroundStyle(LineupStyle.secondary)
        .padding(.horizontal, Metrics.inset)
    }

    private func posterShelf(_ hits: [AppSearchHit]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Metrics.posterGap) {
                ForEach(hits) { hit in
                    poster(hit).frame(width: Metrics.posterWidth)
                }
            }
            .padding(.vertical, Metrics.shelfLift)
        }
        .contentMargins(.horizontal, Metrics.inset, for: .scrollContent)
        .scrollClipDisabled()
        .lineupFocusRegion()
    }

    private func posterGrid(_ hits: [AppSearchHit]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.posterWidth, maximum: Metrics.posterWidth * 1.3),
                                     spacing: Metrics.posterGap, alignment: .top)],
                  alignment: .leading, spacing: Metrics.gridRowGap) {
            ForEach(hits) { hit in poster(hit) }
        }
        .padding(.horizontal, Metrics.inset)
        .lineupFocusRegion()
    }

    @ViewBuilder
    private func poster(_ hit: AppSearchHit) -> some View {
        if let item = AppSearchFormat.item(of: hit) {
            let card = AppSearchPosterCard(item: item, place: AppSearchFormat.place(of: hit))
            #if os(tvOS)
            TVSelectable(drawsFocusChrome: false, action: { open(hit) }) { card }
            #else
            Button { open(hit) } label: { card }.lineupFlatButton()
            #endif
        }
    }

    /// The live results as the guide would list them: games first, then
    /// channels, then programmes, each under its own heading.
    @ViewBuilder
    private func liveSections(_ hits: [AppSearchHit]) -> some View {
        let games = hits.filter { if case .game = $0.kind { true } else { false } }
        let channels = hits.filter { if case .channel = $0.kind { true } else { false } }
        let airings = hits.filter { if case .airing = $0.kind { true } else { false } }
        if !games.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerGap) {
                sectionHeader("Games", count: games.count, seeAll: nil)
                liveList(games)
            }
        }
        if !channels.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerGap) {
                sectionHeader("Channels", count: channels.count, seeAll: nil)
                liveList(channels)
            }
        }
        if !airings.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerGap) {
                sectionHeader("On the TV Guide", count: airings.count, seeAll: nil)
                liveList(airings)
            }
        }
    }

    private func liveList(_ hits: [AppSearchHit]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.rowGap, alignment: .top),
                                 count: Metrics.liveColumns),
                  alignment: .leading, spacing: Metrics.rowGap) {
            ForEach(hits) { hit in
                let row = AppSearchLiveRow(hit: hit)
                #if os(tvOS)
                TVSelectable(scale: LineupStyle.cardLift, fillRadius: Metrics.rowRadius, action: { open(hit) }) { row }
                #else
                Button { open(hit) } label: { row }.lineupFlatButton()
                #endif
            }
        }
        .padding(.horizontal, Metrics.inset)
        .lineupFocusRegion()
    }
}

#if os(tvOS)
/// A channel to play full screen from the Search tab, and the game it was
/// found for, so a game that loses its feed can move to another channel as
/// it would from the Live tab.
private struct AppSearchPlayback: Identifiable {
    let channel: XtreamStream
    let game: SportsGame?
    var id: String { "\(channel.streamID)|\(game?.id ?? "")" }
}
#endif

// MARK: - Pieces

/// A category chip: its name and how many it holds, or a spinner while the
/// servers are still being asked. The chosen one is white.
private struct AppSearchChip: View {
    let title: String
    let count: Int
    let waiting: Bool
    let active: Bool
    #if os(tvOS)
    @Environment(\.lineupTVSelectableFocused) private var focused
    #endif

    private typealias Metrics = AppSearchMetrics

    var body: some View {
        HStack(spacing: Metrics.chipCountGap) {
            Text(title)
                .font(.inter(Metrics.chipSize, .bold))
            if waiting {
                ProgressView().controlSize(.small)
                    .tint(active ? LineupStyle.background : LineupStyle.text)
            } else {
                Text("\(count)")
                    .font(.interDigits(Metrics.chipSize, .bold))
                    .opacity(0.55)
            }
        }
        .foregroundStyle(active ? LineupStyle.background : LineupStyle.text)
        .padding(.horizontal, Metrics.chipPadding)
        .frame(height: Metrics.chipHeight)
        .background(Capsule().fill(active ? Color.white : LineupStyle.surface))
        .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: active ? 0 : 1))
        #if os(tvOS)
        .lineupFocusLayer(focused && !active, in: Capsule())
        #endif
        .animation(.easeOut(duration: 0.18), value: active)
    }
}

private struct AppSearchSeeAll: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("See All")
            Image(systemName: "chevron.right").font(.system(size: AppSearchMetrics.headerSize - 2, weight: .bold))
        }
        .font(.inter(AppSearchMetrics.headerSize + 1, .semibold))
        .foregroundStyle(LineupStyle.text)
        .padding(.horizontal, AppSearchMetrics.seeAllPadding)
        .frame(height: AppSearchMetrics.seeAllHeight)
        .background(Capsule().fill(LineupStyle.surface))
        .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 1))
    }
}

/// Where in the app something is: the tab's own symbol, then the way there.
private struct AppSearchPlace: View {
    let place: AppSearchFormat.Place

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: place.symbol)
                .font(.system(size: AppSearchMetrics.placeSize - 1, weight: .semibold))
            Text(place.path.joined(separator: " › "))
                .font(.inter(AppSearchMetrics.placeSize, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(LineupStyle.secondary)
    }
}

/// A film or a show: its poster and title, as the Library draws it, and
/// under them where it is.
private struct AppSearchPosterCard: View {
    let item: MediaItem
    let place: AppSearchFormat.Place

    var body: some View {
        VStack(alignment: .leading, spacing: AppSearchMetrics.posterPlaceGap) {
            MediaItemCard(item: item, shape: .poster)
            AppSearchPlace(place: place)
                #if os(tvOS)
                .frame(maxWidth: .infinity, alignment: .center)
                #endif
        }
    }
}

/// A game, a channel or a programme in the guide: its picture, what it is,
/// when, and where in the app it is -- with how many more times a programme
/// airs.
private struct AppSearchLiveRow: View {
    let hit: AppSearchHit

    private typealias Metrics = AppSearchMetrics

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
        HStack(alignment: .center, spacing: Metrics.rowInnerGap) {
            AppSearchLiveArt(hit: hit)
            VStack(alignment: .leading, spacing: Metrics.rowLineGap) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(AppSearchFormat.title(of: hit))
                        .font(.inter(Metrics.rowTitleSize, .bold))
                        .lineLimit(1)
                    if let badge = AppSearchFormat.badge(of: hit) {
                        AppSearchBadge(badge: badge)
                    }
                }
                if let detail = AppSearchFormat.detail(of: hit) {
                    Text(detail)
                        .font(.inter(Metrics.rowDetailSize, .medium))
                        .foregroundStyle(LineupStyle.text.opacity(0.78))
                        .lineLimit(1)
                }
                AppSearchPlace(place: AppSearchFormat.place(of: hit))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .airing(_, _, let more, _) = hit.kind, more > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack")
                    Text("+\(more)").font(.interDigits(Metrics.rowDetailSize, .bold))
                }
                .font(.system(size: Metrics.rowDetailSize, weight: .semibold))
                .foregroundStyle(LineupStyle.text.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(height: Metrics.moreHeight)
                .background(Capsule().fill(LineupStyle.raised))
                .accessibilityLabel("\(more) more airings")
            }
        }
        .padding(Metrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupStyle.surface, in: shape)
        .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
        .foregroundStyle(LineupStyle.text)
        .accessibilityElement(children: .combine)
    }
}

/// A row's picture: the two teams' crests for a game, the channel's logo
/// otherwise, with how far through what is on now a bar along its foot.
private struct AppSearchLiveArt: View {
    let hit: AppSearchHit

    private typealias Metrics = AppSearchMetrics

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.artRadius, style: .continuous)
        ZStack {
            LinearGradient(colors: [LineupStyle.raised, LineupStyle.background],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            switch hit.kind {
            case .game(let game, _):
                HStack(spacing: Metrics.crestGap) {
                    crest(game.awayLogo)
                    crest(game.homeLogo)
                }
            case .channel(let channel, _, _), .airing(_, let channel, _, _):
                logo(channel)
            default:
                EmptyView()
            }
        }
        .frame(width: Metrics.artWidth, height: Metrics.artHeight)
        .overlay(alignment: .bottom) {
            if let fraction = AppSearchFormat.progress(of: hit) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white).frame(width: max(4, proxy.size.width * CGFloat(fraction)))
                    }
                }
                .frame(height: Metrics.progressHeight)
                .padding(.horizontal, Metrics.progressInset)
                .padding(.bottom, Metrics.progressInset)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
    }

    private func crest(_ address: String) -> some View {
        LineupArtView(url: URL(string: address), width: Metrics.crestSize) { image in
            if let image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: Metrics.crestSize / 2))
                    .foregroundStyle(LineupStyle.secondary)
            }
        }
        .frame(width: Metrics.crestSize, height: Metrics.crestSize)
    }

    private func logo(_ channel: XtreamStream) -> some View {
        LineupArtView(url: channel.streamIcon.flatMap { URL(string: $0) }, width: Metrics.artWidth) { image in
            if let image {
                image.resizable().scaledToFit()
            } else {
                Text(AppSearchFormat.initials(channel.name))
                    .font(.inter(Metrics.rowTitleSize, .heavy))
                    .foregroundStyle(LineupStyle.secondary)
            }
        }
        .padding(Metrics.logoInset)
    }
}

/// NOW for a programme on now, LIVE for a game being played, the start for
/// one that is not.
private struct AppSearchBadge: View {
    let badge: AppSearchFormat.Badge

    var body: some View {
        Text(badge.text)
            .font(.inter(AppSearchMetrics.badgeSize, .heavy)).tracking(1.2)
            .foregroundStyle(badge.live ? Color.white : LineupStyle.text)
            .padding(.horizontal, 10)
            .frame(height: AppSearchMetrics.badgeHeight)
            .background(Capsule().fill(badge.live ? LineupStyle.liveDot : LineupStyle.raised))
            .fixedSize()
    }
}

/// Before anything is typed: what this tab searches, and that each result
/// says where it is.
private struct AppSearchPrompt: View {
    let searching: Bool

    var body: some View {
        VStack(spacing: AppSearchMetrics.promptGap) {
            if searching {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: AppSearchMetrics.promptSymbol, weight: .semibold))
                    .foregroundStyle(LineupStyle.secondary)
                Text("Search everything")
                    .font(.inter(AppSearchMetrics.promptTitle, .bold))
                Text("Movies and shows on your servers, live channels and games, the TV guide, and your provider’s VOD. Every result shows where it is in the app.")
                    .font(.inter(AppSearchMetrics.promptDetail))
                    .foregroundStyle(LineupStyle.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: AppSearchMetrics.promptWidth)
                HStack(spacing: AppSearchMetrics.promptChipGap) {
                    ForEach(AppSearchCategory.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.inter(AppSearchMetrics.placeSize, .semibold))
                            .foregroundStyle(LineupStyle.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSearchMetrics.promptTop)
        .padding(.horizontal, AppSearchMetrics.inset)
    }
}

private struct AppSearchWaiting: View {
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text(text).font(.inter(AppSearchMetrics.rowDetailSize, .semibold))
                .foregroundStyle(LineupStyle.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct AppSearchEmpty: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppSearchMetrics.promptSymbol * 0.7, weight: .semibold))
                .foregroundStyle(LineupStyle.secondary)
            Text(title).font(.inter(AppSearchMetrics.rowTitleSize, .bold))
                .multilineTextAlignment(.center)
            Text(detail).font(.inter(AppSearchMetrics.rowDetailSize))
                .foregroundStyle(LineupStyle.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppSearchMetrics.promptWidth)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSearchMetrics.promptTop / 2)
        .padding(.horizontal, AppSearchMetrics.inset)
    }
}

// MARK: - Words

/// How a result is put into words: its title, what and when it is, and where
/// in the app it lives.
enum AppSearchFormat {
    /// Where something is: the tab's symbol, and the way there from it.
    struct Place {
        let symbol: String
        let path: [String]
    }

    struct Badge {
        let text: String
        let live: Bool
    }

    static func item(of hit: AppSearchHit) -> MediaItem? {
        switch hit.kind {
        case .title(let item, _), .vod(let item, _): item
        default: nil
        }
    }

    static func title(of hit: AppSearchHit) -> String {
        switch hit.kind {
        case .title(let item, _), .vod(let item, _): item.name
        case .game(let game, _): matchup(game)
        case .channel(let channel, _, _): channel.name
        case .airing(let program, _, _, _): program.title
        }
    }

    static func matchup(_ game: SportsGame) -> String {
        if let event = game.eventName?.trimmingCharacters(in: .whitespacesAndNewlines), !event.isEmpty {
            return event
        }
        return game.awayTeam + " at " + game.homeTeam
    }

    static func badge(of hit: AppSearchHit, now: Date = Date()) -> Badge? {
        switch hit.kind {
        case .game(let game, _):
            if game.isLive {
                let score = game.awayScore.isEmpty || game.homeScore.isEmpty ? "" : " \(game.awayScore)–\(game.homeScore)"
                return Badge(text: "LIVE" + score, live: true)
            }
            return Badge(text: game.startLabel.uppercased(), live: false)
        case .airing(let program, _, _, _):
            return program.start <= now && now < program.end ? Badge(text: "NOW", live: false) : nil
        default:
            return nil
        }
    }

    /// What and when: the league and its channel for a game; what is on now
    /// for a channel; the channel and the time for a programme.
    static func detail(of hit: AppSearchHit, now: Date = Date()) -> String? {
        switch hit.kind {
        case .game(let game, let channel):
            var parts = [game.league.shortName]
            if !game.isLive { parts.append(day(game.start) + " · " + game.start.formatted(date: .omitted, time: .shortened)) }
            parts.append(channel?.name ?? "No channel matched yet")
            return parts.joined(separator: " · ")
        case .channel(_, let current, _):
            guard let current else { return "No listing on now" }
            return "Now: " + current.title + " · until " + current.end.formatted(date: .omitted, time: .shortened)
        case .airing(let program, let channel, _, _):
            let times = program.start.formatted(date: .omitted, time: .shortened)
                + " – " + program.end.formatted(date: .omitted, time: .shortened)
            let live = program.start <= now && now < program.end
            return channel.name + " · " + (live ? times : day(program.start) + " · " + times)
        case .title(let item, _), .vod(let item, _):
            return item.productionYear.map(String.init)
        }
    }

    /// Where the result lives: the Library and the servers that have it; the
    /// Library's VOD shelves and the provider's category; the Guide and the
    /// channel's group or the channel; the Live tab and the league.
    static func place(of hit: AppSearchHit) -> Place {
        switch hit.kind {
        case .title(_, let servers):
            return Place(symbol: "play.square.stack", path: ["Library", servers.joined(separator: " · ")])
        case .vod(_, let group):
            return Place(symbol: "play.square.stack", path: ["Library", "VOD"] + (group.map { [$0] } ?? []))
        case .game(let game, _):
            return Place(symbol: "play.rectangle", path: ["Live", game.league.shortName])
        case .channel(_, _, let group):
            return Place(symbol: "list.bullet.rectangle", path: ["Guide"] + (group.map { [$0] } ?? []))
        case .airing(_, let channel, _, let group):
            return Place(symbol: "list.bullet.rectangle", path: ["Guide"] + (group.map { [$0] } ?? [channel.name]))
        }
    }

    /// How far through it is, for what is on now: a programme on now, a
    /// channel's current programme.
    static func progress(of hit: AppSearchHit, now: Date = Date()) -> Double? {
        let program: CurrentProgram?
        switch hit.kind {
        case .channel(_, let current, _): program = current
        case .airing(let airing, _, _, _): program = airing
        default: program = nil
        }
        guard let program, program.start <= now, now < program.end else { return nil }
        let length = program.end.timeIntervalSince(program.start)
        guard length > 0 else { return nil }
        return min(1, max(0, now.timeIntervalSince(program.start) / length))
    }

    /// "Today", "Tomorrow", or the day: "Thu, Oct 8".
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// A channel without a logo is drawn by the first letters of its name.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

// MARK: - Sizes

private enum AppSearchMetrics {
    #if os(tvOS)
    static let inset: CGFloat = 80
    static let topInset: CGFloat = 24
    static let bottomInset: CGFloat = 80
    static let sectionGap: CGFloat = 54
    static let headerGap: CGFloat = 18
    static let headerSize: CGFloat = 16
    static let headerTracking: CGFloat = 2.2
    static let chipGap: CGFloat = 16
    static let chipSize: CGFloat = 22
    static let chipHeight: CGFloat = 56
    static let chipPadding: CGFloat = 26
    static let chipCountGap: CGFloat = 12
    static let chipLift: CGFloat = 12
    static let seeAllPadding: CGFloat = 18
    static let seeAllHeight: CGFloat = 40
    static let posterWidth: CGFloat = 220
    static let posterGap: CGFloat = 30
    static let posterPlaceGap: CGFloat = 4
    static let gridRowGap: CGFloat = 44
    static let shelfLift: CGFloat = 12
    static let placeSize: CGFloat = 16
    static let liveColumns = 2
    static let liveInAll = 6
    static let rowGap: CGFloat = 22
    static let rowInnerGap: CGFloat = 22
    static let rowLineGap: CGFloat = 6
    static let rowPadding: CGFloat = 16
    static let rowRadius: CGFloat = 20
    static let rowTitleSize: CGFloat = 25
    static let rowDetailSize: CGFloat = 19
    static let artWidth: CGFloat = 176
    static let artHeight: CGFloat = 99
    static let artRadius: CGFloat = 12
    static let logoInset: CGFloat = 16
    static let crestSize: CGFloat = 56
    static let crestGap: CGFloat = 14
    static let progressHeight: CGFloat = 5
    static let progressInset: CGFloat = 9
    static let badgeSize: CGFloat = 14
    static let badgeHeight: CGFloat = 26
    static let moreHeight: CGFloat = 42
    static let promptTop: CGFloat = 90
    static let promptGap: CGFloat = 18
    static let promptSymbol: CGFloat = 54
    static let promptTitle: CGFloat = 38
    static let promptDetail: CGFloat = 22
    static let promptWidth: CGFloat = 900
    static let promptChipGap: CGFloat = 34
    #else
    static let inset: CGFloat = 16
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 32
    static let sectionGap: CGFloat = 28
    static let headerGap: CGFloat = 12
    static let headerSize: CGFloat = 13
    static let headerTracking: CGFloat = 1.4
    static let chipGap: CGFloat = 10
    static let chipSize: CGFloat = 16
    static let chipHeight: CGFloat = 40
    static let chipPadding: CGFloat = 18
    static let chipCountGap: CGFloat = 8
    static let chipLift: CGFloat = 2
    static let seeAllPadding: CGFloat = 12
    static let seeAllHeight: CGFloat = 30
    static let posterWidth: CGFloat = 116
    static let posterGap: CGFloat = 12
    static let posterPlaceGap: CGFloat = 2
    static let gridRowGap: CGFloat = 20
    static let shelfLift: CGFloat = 2
    static let placeSize: CGFloat = 11
    static let liveColumns = 1
    static let liveInAll = 5
    static let rowGap: CGFloat = 10
    static let rowInnerGap: CGFloat = 12
    static let rowLineGap: CGFloat = 3
    static let rowPadding: CGFloat = 10
    static let rowRadius: CGFloat = 16
    static let rowTitleSize: CGFloat = 16
    static let rowDetailSize: CGFloat = 13
    static let artWidth: CGFloat = 96
    static let artHeight: CGFloat = 54
    static let artRadius: CGFloat = 8
    static let logoInset: CGFloat = 8
    static let crestSize: CGFloat = 30
    static let crestGap: CGFloat = 6
    static let progressHeight: CGFloat = 3
    static let progressInset: CGFloat = 5
    static let badgeSize: CGFloat = 10
    static let badgeHeight: CGFloat = 18
    static let moreHeight: CGFloat = 30
    static let promptTop: CGFloat = 60
    static let promptGap: CGFloat = 12
    static let promptSymbol: CGFloat = 38
    static let promptTitle: CGFloat = 24
    static let promptDetail: CGFloat = 15
    static let promptWidth: CGFloat = 340
    static let promptChipGap: CGFloat = 14
    #endif
}
