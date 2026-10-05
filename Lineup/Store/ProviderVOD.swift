import Foundation

/// The IPTV provider's films and shows, as one more place a Library title's
/// streams can come from.
///
/// The provider has no search, so its whole list is read once and kept: on
/// the device between launches, and asked for again after twelve hours. A
/// title is found in it by its TMDB id where the provider records one, and
/// otherwise by its name and year once the provider's decoration is gone.
@MainActor
final class ProviderVOD {
    /// What the provider holds, and when it was read.
    struct Catalog: Sendable {
        let profileID: UUID
        let films: [XtreamVODStream]
        let shows: [XtreamSeries]
        /// How the provider groups its films and its shows, for shelves.
        var filmCategories: [XtreamCategory] = []
        var showCategories: [XtreamCategory] = []
        let fetchedAt: Date

        var isStale: Bool { Date().timeIntervalSince(fetchedAt) > ProviderVOD.lifetime }
    }

    /// Where a title is in the catalog: by TMDB id and by name.
    struct Index: Sendable {
        /// One of the provider's titles filed under a name, with the year
        /// that filing means.
        private struct Entry: Sendable {
            let index: Int
            let year: Int?
        }

        private var filmsByTMDB: [String: [Int]] = [:]
        private var filmsByName: [String: [Entry]] = [:]
        private var showsByTMDB: [String: [Int]] = [:]
        private var showsByName: [String: [Entry]] = [:]
        private var filmPositions: [Int: Int] = [:]
        private var showPositions: [Int: Int] = [:]
        private var filmsByCategory: [String: [Int]] = [:]
        private var showsByCategory: [String: [Int]] = [:]
        /// Each title's first filing, what a search is matched against.
        private var filmKeys: [String] = []
        private var showKeys: [String] = []

        /// Filed by working out each title's filings, as a list fresh from
        /// the provider needs once.
        init(_ catalog: Catalog) {
            self.init(catalog, filmFilings: catalog.films.map { ProviderTitle.filings(for: $0.name) },
                      showFilings: catalog.shows.map { ProviderTitle.filings(for: $0.name) })
        }

        /// Filed by filings already worked out, one list per title in the
        /// catalog's order, as the copy kept on the device has them.
        init(_ catalog: Catalog, filmFilings: [[ProviderTitle.Filed]], showFilings: [[ProviderTitle.Filed]]) {
            for (index, film) in catalog.films.enumerated() {
                filmPositions[film.streamID] = filmPositions[film.streamID] ?? index
                if let category = film.categoryID { filmsByCategory[category, default: []].append(index) }
                if let tmdb = film.tmdbID { filmsByTMDB[tmdb, default: []].append(index) }
                let filings = index < filmFilings.count ? filmFilings[index] : []
                filmKeys.append(filings.first?.key ?? "")
                for filed in filings {
                    filmsByName[filed.key, default: []].append(Entry(index: index, year: film.year ?? filed.year))
                }
            }
            for (index, show) in catalog.shows.enumerated() {
                showPositions[show.seriesID] = showPositions[show.seriesID] ?? index
                if let category = show.categoryID { showsByCategory[category, default: []].append(index) }
                if let tmdb = show.tmdbID { showsByTMDB[tmdb, default: []].append(index) }
                let filings = index < showFilings.count ? showFilings[index] : []
                showKeys.append(filings.first?.key ?? "")
                for filed in filings {
                    showsByName[filed.key, default: []].append(Entry(index: index, year: show.year ?? filed.year))
                }
            }
        }

        func film(streamID: Int, in catalog: Catalog) -> XtreamVODStream? {
            filmPositions[streamID].map { catalog.films[$0] }
        }

        func show(seriesID: Int, in catalog: Catalog) -> XtreamSeries? {
            showPositions[seriesID].map { catalog.shows[$0] }
        }

        /// A category's films or shows, in the provider's own order.
        func films(inCategory category: String, in catalog: Catalog) -> [XtreamVODStream] {
            (filmsByCategory[category] ?? []).map { catalog.films[$0] }
        }

        func shows(inCategory category: String, in catalog: Catalog) -> [XtreamSeries] {
            (showsByCategory[category] ?? []).map { catalog.shows[$0] }
        }

        /// The films and shows whose names hold the search, as the provider's
        /// search would have if it had one: a name that is the search first,
        /// then one that starts with it, then one that has it anywhere.
        func search(_ term: String, in catalog: Catalog, limit: Int = 60)
            -> (films: [XtreamVODStream], shows: [XtreamSeries]) {
            let wanted = MediaTitleMatch.normalized(term)
            guard !wanted.isEmpty else { return ([], []) }
            func ranked(_ keys: [String]) -> [Int] {
                var exact: [Int] = [], starting: [Int] = [], within: [Int] = []
                for (index, key) in keys.enumerated() where key.contains(wanted) {
                    if key == wanted { exact.append(index) }
                    else if key.hasPrefix(wanted) { starting.append(index) }
                    else { within.append(index) }
                }
                return Array((exact + starting + within).prefix(limit))
            }
            return (ranked(filmKeys).map { catalog.films[$0] }, ranked(showKeys).map { catalog.shows[$0] })
        }

        /// The provider's films that are this title.
        func films(for title: MediaItem, in catalog: Catalog) -> [XtreamVODStream] {
            Self.matches(for: title, byTMDB: filmsByTMDB, byName: filmsByName,
                         tmdbOf: { catalog.films[$0].tmdbID }).map { catalog.films[$0] }
        }

        /// The provider's shows that are this show.
        func shows(for show: MediaItem, in catalog: Catalog) -> [XtreamSeries] {
            Self.matches(for: show, byTMDB: showsByTMDB, byName: showsByName,
                         tmdbOf: { catalog.shows[$0].tmdbID }).map { catalog.shows[$0] }
        }

        /// Everything filed under the title's TMDB id, and everything filed
        /// under its name whose year agrees and whose own TMDB id, if it has
        /// one, is not some other title's. A provider often lists a film more
        /// than once -- 4K and HD, or in two languages -- and each is a stream.
        private static func matches(for title: MediaItem, byTMDB: [String: [Int]],
                                    byName: [String: [Entry]], tmdbOf: (Int) -> String?) -> [Int] {
            let tmdb = MediaTitleMatch.providerIDs(of: title)["tmdb"]
            var found = tmdb.flatMap { byTMDB[$0] } ?? []
            let name = MediaTitleMatch.normalized(title.name)
            guard !name.isEmpty else { return found }
            for entry in byName[name] ?? [] where !found.contains(entry.index) {
                if let tmdb, let theirs = tmdbOf(entry.index), theirs != tmdb { continue }
                if let wanted = title.productionYear, let year = entry.year, abs(wanted - year) > 1 { continue }
                found.append(entry.index)
            }
            return found
        }
    }

    /// Why the provider added nothing.
    enum Miss: LocalizedError {
        case noProvider

        var errorDescription: String? { "No IPTV provider is signed in" }
    }

    nonisolated static let lifetime: TimeInterval = 12 * 60 * 60

    private let defaults: UserDefaults
    private var loaded: (catalog: Catalog, index: Index)?
    private var loading: Task<(catalog: Catalog, index: Index), Error>?
    private var refreshing: Task<Void, Never>?
    private var episodeLists: [String: (episodes: [XtreamEpisode], storedAt: Date)] = [:]
    /// Shows whose episodes are being asked for, so a title page getting
    /// them ready and the stream list wanting them make one request.
    private var episodeLoads: [String: Task<[XtreamEpisode], Error>] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The provider in use, without its password: cheap enough to ask on every
    /// redraw, which Continue Watching does.
    var profile: XtreamProfile? {
        let now = Date()
        if let remembered, now.timeIntervalSince(remembered.readAt) < 5 { return remembered.profile }
        let profile = SportsLibrary.storedActiveProfile(in: defaults)
        remembered = (profile, now)
        return profile
    }
    private var remembered: (profile: XtreamProfile?, readAt: Date)?

    /// The catalog and its index when they are already in hand, without
    /// waiting for them.
    var ready: (catalog: Catalog, index: Index)? {
        guard let loaded, loaded.catalog.profileID == profile?.id else { return nil }
        return loaded
    }

    /// The provider in use and a client for it, or nil when none is signed in.
    var provider: (profile: XtreamProfile, client: XtreamClient)? {
        guard let profile = SportsLibrary.storedActiveProfile(in: defaults),
              let password = KeychainStore.password(profileID: profile.id) else { return nil }
        return (profile, XtreamClient(profile: profile, password: password))
    }

    /// How many films and shows the provider's list holds, once it has been
    /// read: how wide a search came up empty.
    var counts: (films: Int, shows: Int)? {
        loaded.map { (films: $0.catalog.films.count, shows: $0.catalog.shows.count) }
    }

    /// The catalog and its index: kept in memory, read from the device when
    /// the app has just started, and asked of the provider when neither has
    /// it. A catalog past its lifetime is used while a fresh one is fetched.
    func catalog() async throws -> (catalog: Catalog, index: Index) {
        guard let provider else { throw Miss.noProvider }
        if let loaded, loaded.catalog.profileID == provider.profile.id {
            if loaded.catalog.isStale { refresh(provider) }
            return loaded
        }
        if let loading { return try await loading.value }
        let profileID = provider.profile.id
        let client = provider.client
        let task = Task.detached(priority: .userInitiated) { () async throws -> (catalog: Catalog, index: Index) in
            if let saved = Self.readCache(profileID: profileID) { return saved }
            if let earlier = Self.readEarlierCache(profileID: profileID) { return Self.kept(earlier) }
            return Self.prepared(try await Self.fetch(client, profileID: profileID))
        }
        loading = task
        do {
            let result = try await task.value
            loading = nil
            // Another provider may have been chosen while this one loaded.
            guard self.provider?.profile.id == profileID else { throw Miss.noProvider }
            loaded = result
            if result.catalog.isStale { refresh(provider) }
            return result
        } catch {
            loading = nil
            throw error
        }
    }

    /// What a lookup would wait for before it could look, for the stream list
    /// to say rather than leave a provider "looking" for a minute: nothing
    /// once the list is in memory.
    var waitNote: String? {
        guard let profile, ready == nil else { return nil }
        return Self.hasCache(profileID: profile.id) ? "Reading its list…" : "Downloading its list…"
    }

    /// Start reading the catalog without waiting for it, so the first title
    /// played does not wait on the whole list. Only from the device, when
    /// asked: at the launch of an app with no media server, a list that has
    /// never been read is left for the Library to ask for, rather than
    /// downloaded for someone who may never open it.
    func prefetch(onlyFromDevice: Bool = false) {
        guard let provider, loaded == nil, loading == nil else { return }
        if onlyFromDevice, !Self.hasCache(profileID: provider.profile.id) { return }
        Task { _ = try? await catalog() }
    }

    /// One show's episodes. Kept for a while: a season is watched one episode
    /// after another, and the list does not change in between.
    func episodes(of show: XtreamSeries) async throws -> [XtreamEpisode] {
        guard let provider else { throw Miss.noProvider }
        let key = provider.profile.id.uuidString + "|" + String(show.seriesID)
        if let kept = episodeLists[key], Date().timeIntervalSince(kept.storedAt) < 30 * 60 {
            return kept.episodes
        }
        if let pending = episodeLoads[key] { return try await pending.value }
        let client = provider.client
        let load = Task { try await client.seriesInfo(seriesID: show.seriesID).episodes }
        episodeLoads[key] = load
        defer { if episodeLoads[key] == load { episodeLoads[key] = nil } }
        let episodes = try await load.value
        episodeLists[key] = (episodes, Date())
        return episodes
    }

    /// Forget everything about the provider, as when it changes.
    func reset() {
        loading?.cancel()
        loading = nil
        refreshing?.cancel()
        refreshing = nil
        loaded = nil
        episodeLists.removeAll()
        episodeLoads.values.forEach { $0.cancel() }
        episodeLoads.removeAll()
    }

    private func refresh(_ provider: (profile: XtreamProfile, client: XtreamClient)) {
        guard refreshing == nil else { return }
        let profileID = provider.profile.id
        let client = provider.client
        refreshing = Task { [weak self] in
            let fresh = try? await Task.detached(priority: .utility) { () async throws -> (catalog: Catalog, index: Index) in
                Self.prepared(try await Self.fetch(client, profileID: profileID))
            }.value
            guard let self else { return }
            self.refreshing = nil
            if let fresh, self.provider?.profile.id == profileID { self.loaded = fresh }
        }
    }

    /// Films and shows together. A provider that lists only one of the two
    /// still has that one; only both failing is a failure.
    nonisolated private static func fetch(_ client: XtreamClient, profileID: UUID) async throws -> Catalog {
        async let films = capture { try await client.vodStreams() }
        async let shows = capture { try await client.series() }
        async let filmGroups = capture { try await client.vodCategories() }
        async let showGroups = capture { try await client.seriesCategories() }
        let (filmList, showList) = await (films, shows)
        let (filmCategories, showCategories) = await (filmGroups, showGroups)
        switch (filmList, showList) {
        case (.failure(let error), .failure):
            throw error
        default:
            return Catalog(profileID: profileID, films: (try? filmList.get()) ?? [],
                           shows: (try? showList.get()) ?? [],
                           filmCategories: (try? filmCategories.get()) ?? [],
                           showCategories: (try? showCategories.get()) ?? [], fetchedAt: Date())
        }
    }

    nonisolated private static func capture<T: Sendable>(
        _ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    // MARK: - The copy kept on the device

    /// A list fresh from the provider, filed and written down. Each name is
    /// cleaned and filed here, once; the copy kept on the device carries the
    /// result, so a launch reads it back rather than working it out again.
    nonisolated private static func prepared(_ catalog: Catalog) -> (catalog: Catalog, index: Index) {
        kept(ProviderVODFile.Contents(catalog: catalog,
                                      filmFilings: catalog.films.map { ProviderTitle.filings(for: $0.name) },
                                      showFilings: catalog.shows.map { ProviderTitle.filings(for: $0.name) }))
    }

    /// A filed list, written down for the next launch after it is handed
    /// back: nothing waits on the disk.
    nonisolated private static func kept(_ contents: ProviderVODFile.Contents) -> (catalog: Catalog, index: Index) {
        Task.detached(priority: .utility) { Self.writeCache(contents) }
        return indexed(contents)
    }

    nonisolated private static func indexed(_ contents: ProviderVODFile.Contents) -> (catalog: Catalog, index: Index) {
        (contents.catalog, Index(contents.catalog, filmFilings: contents.filmFilings,
                                 showFilings: contents.showFilings))
    }

    nonisolated private static var cachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    nonisolated static func cacheURL(profileID: UUID) -> URL? {
        cachesDirectory?.appendingPathComponent("Lineup-provider-vod-v3-\(profileID.uuidString).txt")
    }

    /// Where the previous builds kept the list, as JSON.
    nonisolated static func earlierCacheURL(profileID: UUID) -> URL? {
        cachesDirectory?.appendingPathComponent("Lineup-provider-vod-v2-\(profileID.uuidString).json")
    }

    /// Where the first builds kept it, in the panel's own keys. No longer
    /// read: only removed.
    nonisolated static func firstCacheURL(profileID: UUID) -> URL? {
        cachesDirectory?.appendingPathComponent("Lineup-provider-vod-\(profileID.uuidString).json")
    }

    nonisolated private static func hasCache(profileID: UUID) -> Bool {
        [cacheURL(profileID: profileID), earlierCacheURL(profileID: profileID)].contains { url in
            url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    nonisolated static func readCache(profileID: UUID) -> (catalog: Catalog, index: Index)? {
        guard let url = cacheURL(profileID: profileID),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let contents = ProviderVODFile.decode(data, profileID: profileID) else { return nil }
        return indexed(contents)
    }

    nonisolated static func writeCache(_ contents: ProviderVODFile.Contents) {
        guard let url = cacheURL(profileID: contents.catalog.profileID) else { return }
        try? ProviderVODFile.encode(contents).write(to: url, options: .atomic)
    }

    /// The list as the previous builds kept it: read once, so updating the
    /// app does not mean downloading the whole list again, then kept in the
    /// new form and removed -- with the first builds' copy, if one is still
    /// about.
    nonisolated static func readEarlierCache(profileID: UUID) -> ProviderVODFile.Contents? {
        if let first = firstCacheURL(profileID: profileID) { try? FileManager.default.removeItem(at: first) }
        guard let url = earlierCacheURL(profileID: profileID), let data = try? Data(contentsOf: url) else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        guard let saved = try? JSONDecoder().decode(Earlier.self, from: data),
              saved.version == 2, saved.profileID == profileID else { return nil }
        let films = saved.films.map { film in
            XtreamVODStream(streamID: film.i, name: film.n, icon: film.p, categoryID: film.c,
                            containerExtension: film.x, rating: film.r, tmdbID: film.t, year: film.y)
        }
        let shows = saved.shows.map { show in
            XtreamSeries(seriesID: show.i, name: show.n, cover: show.p, plot: show.o, genre: show.g,
                         rating: show.r, backdrop: show.b, categoryID: show.c, tmdbID: show.t, year: show.y)
        }
        let catalog = Catalog(profileID: profileID, films: films, shows: shows,
                              filmCategories: saved.filmCategories, showCategories: saved.showCategories,
                              fetchedAt: saved.fetchedAt)
        return ProviderVODFile.Contents(
            catalog: catalog,
            filmFilings: saved.films.map { film in film.f.map { ProviderTitle.Filed(key: $0.k, year: $0.y) } },
            showFilings: saved.shows.map { show in show.f.map { ProviderTitle.Filed(key: $0.k, year: $0.y) } })
    }

    /// The previous builds' copy: short keys, and each title's filings.
    private struct Earlier: Decodable {
        let version: Int
        let profileID: UUID
        let fetchedAt: Date
        let films: [Film]
        let shows: [Show]
        let filmCategories: [XtreamCategory]
        let showCategories: [XtreamCategory]

        struct Filing: Decodable {
            let k: String
            let y: Int?
        }

        struct Film: Decodable {
            let i: Int
            let n: String
            let p: String?
            let c: String?
            let x: String?
            let r: Double?
            let t: String?
            let y: Int?
            let f: [Filing]
        }

        struct Show: Decodable {
            let i: Int
            let n: String
            let p: String?
            let o: String?
            let g: String?
            let r: Double?
            let b: String?
            let c: String?
            let t: String?
            let y: Int?
            let f: [Filing]
        }
    }

    // MARK: - The provider's titles as Library items
    //
    // Each carries the provider as its server and its artwork as addresses,
    // the way an MDBList title does, so the Library draws it like any other.

    nonisolated static func item(for film: XtreamVODStream, provider: UUID) -> MediaItem {
        MediaItem(id: ProviderItem.film(streamID: film.streamID).id,
                  name: ProviderTitle.displayName(for: film.name), type: "Movie", overview: nil,
                  productionYear: film.year, primaryImageAspectRatio: nil, childCount: nil,
                  communityRating: film.rating, providerIDs: film.tmdbID.map { ["Tmdb": $0] },
                  posterURL: film.icon, serverID: provider)
    }

    nonisolated static func item(for show: XtreamSeries, provider: UUID) -> MediaItem {
        MediaItem(id: ProviderItem.series(seriesID: show.seriesID).id,
                  name: ProviderTitle.displayName(for: show.name), type: "Series", overview: show.plot,
                  productionYear: show.year, primaryImageAspectRatio: nil, childCount: nil,
                  genres: show.genre.map(list(in:)), communityRating: show.rating,
                  providerIDs: show.tmdbID.map { ["Tmdb": $0] },
                  posterURL: show.cover, backdropURL: show.backdrop, serverID: provider)
    }

    /// A show's seasons, as its episodes number them: "Specials" for season 0.
    nonisolated static func seasons(of show: XtreamSeries, episodes: [XtreamEpisode],
                                    provider: UUID) -> [MediaItem] {
        Set(episodes.map(\.season)).sorted().map { number in
            MediaItem(id: ProviderItem.season(seriesID: show.seriesID, number: number).id,
                      name: number == 0 ? "Specials" : "Season \(number)", type: "Season", overview: nil,
                      productionYear: nil, primaryImageAspectRatio: nil,
                      childCount: episodes.filter { $0.season == number }.count,
                      indexNumber: number, seriesName: ProviderTitle.displayName(for: show.name),
                      seriesID: ProviderItem.series(seriesID: show.seriesID).id,
                      posterURL: show.cover, serverID: provider)
        }
    }

    nonisolated static func item(for episode: XtreamEpisode, of show: XtreamSeries,
                                 provider: UUID) -> MediaItem {
        MediaItem(id: ProviderItem.episode(seriesID: show.seriesID, episodeID: episode.id).id,
                  name: ProviderTitle.episodeName(episode.title, number: episode.episodeNumber),
                  type: "Episode", overview: episode.plot, productionYear: nil,
                  primaryImageAspectRatio: 16.0 / 9.0, childCount: nil,
                  runTimeTicks: episode.durationSeconds.map { Int64($0) * 10_000_000 },
                  indexNumber: episode.episodeNumber, parentIndexNumber: episode.season,
                  seriesName: ProviderTitle.displayName(for: show.name),
                  seriesID: ProviderItem.series(seriesID: show.seriesID).id,
                  posterURL: episode.image ?? show.backdrop ?? show.cover, serverID: provider)
    }

    /// A category, as the root of a shelf of its films or its shows, with how
    /// many it holds.
    nonisolated static func shelfRoot(for category: XtreamCategory, films: Bool, count: Int? = nil,
                                      provider: UUID) -> MediaItem {
        let item: ProviderItem = films ? .filmCategory(category.categoryID) : .seriesCategory(category.categoryID)
        return MediaItem(id: item.id, name: category.categoryName, type: "CollectionFolder", overview: nil,
                         productionYear: nil, primaryImageAspectRatio: nil, childCount: count, serverID: provider)
    }

    /// A list the provider writes as one string: "Science Fiction, Adventure"
    /// as two genres, a cast as its names.
    nonisolated static func list(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
