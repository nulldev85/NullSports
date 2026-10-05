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
    struct Catalog: Codable, Sendable {
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

        init(_ catalog: Catalog) {
            for (index, film) in catalog.films.enumerated() {
                filmPositions[film.streamID] = filmPositions[film.streamID] ?? index
                if let category = film.categoryID { filmsByCategory[category, default: []].append(index) }
                if let tmdb = film.tmdbID { filmsByTMDB[tmdb, default: []].append(index) }
                let filings = ProviderTitle.filings(for: film.name)
                filmKeys.append(filings.first?.key ?? "")
                for filed in filings {
                    filmsByName[filed.key, default: []].append(Entry(index: index, year: film.year ?? filed.year))
                }
            }
            for (index, show) in catalog.shows.enumerated() {
                showPositions[show.seriesID] = showPositions[show.seriesID] ?? index
                if let category = show.categoryID { showsByCategory[category, default: []].append(index) }
                if let tmdb = show.tmdbID { showsByTMDB[tmdb, default: []].append(index) }
                let filings = ProviderTitle.filings(for: show.name)
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
            if let saved = Self.readCache(profileID: profileID) { return (saved, Index(saved)) }
            let fresh = try await Self.fetch(client, profileID: profileID)
            Self.writeCache(fresh)
            return (fresh, Index(fresh))
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

    /// Start reading the catalog without waiting for it, so the first title
    /// played does not wait on the whole list.
    func prefetch() {
        guard provider != nil, loaded == nil, loading == nil else { return }
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
        let episodes = try await provider.client.seriesInfo(seriesID: show.seriesID).episodes
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
    }

    private func refresh(_ provider: (profile: XtreamProfile, client: XtreamClient)) {
        guard refreshing == nil else { return }
        let profileID = provider.profile.id
        let client = provider.client
        refreshing = Task { [weak self] in
            let fresh = try? await Task.detached(priority: .utility) { () async throws -> (catalog: Catalog, index: Index) in
                let fresh = try await Self.fetch(client, profileID: profileID)
                Self.writeCache(fresh)
                return (fresh, Index(fresh))
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

    nonisolated private static func cacheURL(profileID: UUID) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lineup-provider-vod-\(profileID.uuidString).json")
    }

    nonisolated private static func readCache(profileID: UUID) -> Catalog? {
        guard let url = cacheURL(profileID: profileID), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Catalog.self, from: data),
              saved.profileID == profileID else { return nil }
        return saved
    }

    nonisolated private static func writeCache(_ catalog: Catalog) {
        guard let url = cacheURL(profileID: catalog.profileID),
              let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: url, options: .atomic)
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
