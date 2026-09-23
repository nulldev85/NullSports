import Foundation

/// The active provider's films and series, and how far through them a viewer is.
///
/// Built to be cheap until it is used. On a provider change it reads two short
/// category lists -- enough to know whether the provider offers anything on
/// demand at all, which decides whether the tab is shown. A category's titles
/// are fetched when its shelf first comes on screen, and the whole catalogue
/// only when a viewer searches it. Each answer is kept on disk per provider,
/// so the next launch draws immediately and checks for changes behind it.
@MainActor
final class OnDemandLibrary: ObservableObject {
    enum CatalogState: Equatable {
        case idle
        case loading
        case ready
        /// The provider answered and has nothing on demand.
        case empty
        case failed(String)
    }

    enum Load: Equatable { case loading, loaded, failed }

    @Published private(set) var profileID: UUID?
    @Published private(set) var state: CatalogState = .idle
    @Published private(set) var categories: [OnDemandKind: [OnDemandCategory]] = [:]
    /// Keyed by `shelfKey`.
    @Published private(set) var shelves: [String: [OnDemandTitle]] = [:]
    @Published private(set) var shelfLoads: [String: Load] = [:]
    @Published private(set) var searchLoads: [OnDemandKind: Load] = [:]
    @Published private(set) var playbacks: [String: OnDemandPlayback] = [:]

    private var profile: XtreamProfile?
    /// Stamps every request with the provider it was made for. An answer that
    /// arrives after a switch belongs to the provider before and is dropped.
    private var generation = UUID()
    private var validatedShelves: Set<String> = []
    private var validatedSearch: Set<OnDemandKind> = []
    private var searchEntries: [OnDemandKind: [OnDemandSearchEntry]] = [:]
    private var movieDetails: [String: OnDemandMovieDetail] = [:]
    private var seriesDetails: [String: OnDemandSeriesDetail] = [:]
    private var knownProfileIDs: Set<UUID>?
    private var categoryRefresh: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let playbackKey = "Lineup.onDemandPlayback"
    /// A provider's panel is one server, often a small one. A screen of shelves
    /// asking at once is a burst it may answer by refusing, so a few go at a time.
    private let maximumConcurrentRequests = 3
    private var requestsInFlight = 0
    private var waitingRequests: [CheckedContinuation<Void, Never>] = []

    // MARK: Provider

    /// Whether the tab has anything to offer: a provider, and one that has not
    /// said it carries nothing on demand.
    var isAvailable: Bool { profileID != nil && state != .empty }

    func activate(_ profile: XtreamProfile?) {
        guard profile?.id != profileID else {
            self.profile = profile
            return
        }
        generation = UUID()
        categoryRefresh?.cancel()
        self.profile = profile
        profileID = profile?.id
        categories = [:]
        shelves = [:]
        shelfLoads = [:]
        searchLoads = [:]
        validatedShelves = []
        validatedSearch = []
        searchEntries = [:]
        movieDetails = [:]
        seriesDetails = [:]
        playbacks = [:]
        state = .idle
        guard let profile else { return }
        restorePlaybacks(profileID: profile.id)
        if let cached: [OnDemandKind: [OnDemandCategory]] = Self.read(Self.cacheURL(profile.id, "categories")) {
            categories = cached
            state = Self.state(for: cached)
        }
        let generation = generation
        categoryRefresh = Task { [weak self] in
            // Live is what a launch is for. Two short lists can wait for it.
            if self?.categories.isEmpty == false {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
            await self?.refreshCategories(generation: generation)
        }
    }

    /// Forgets the progress and the caches of a provider that has been removed.
    ///
    /// Only a provider seen in one list and missing from the next counts as
    /// removed. The first list of a launch establishes who exists; an empty
    /// list mid-import is not taken as every provider leaving at once.
    func providersChanged(_ profiles: [XtreamProfile]) {
        let current = Set(profiles.map(\.id))
        defer { knownProfileIDs = current }
        guard let known = knownProfileIDs, !current.isEmpty else { return }
        for removed in known.subtracting(current) {
            defaults.removeObject(forKey: playbackKey + "." + removed.uuidString)
            let prefix = "lineup-ondemand-\(removed.uuidString)-"
            let directory = Self.cacheDirectory()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where file.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }

    func refresh() {
        validatedShelves = []
        validatedSearch = []
        movieDetails = [:]
        seriesDetails = [:]
        let generation = generation
        categoryRefresh?.cancel()
        categoryRefresh = Task { [weak self] in await self?.refreshCategories(generation: generation) }
    }

    private func refreshCategories(generation: UUID) async {
        guard let client = client(), generation == self.generation else { return }
        if categories.isEmpty { state = .loading }
        var fresh = categories
        var failure: Error?
        var answered = 0
        for kind in OnDemandKind.allCases {
            do {
                let list = try await gated { try await client.onDemandCategories(kind) }
                fresh[kind] = list
                answered += 1
            } catch {
                failure = error
            }
            guard generation == self.generation, !Task.isCancelled else { return }
        }
        guard answered > 0 else {
            if categories.isEmpty {
                state = .failed(failure?.localizedDescription ?? "The provider did not answer.")
            }
            return
        }
        categories = fresh
        state = Self.state(for: fresh)
        if let profileID { Self.write(fresh, to: Self.cacheURL(profileID, "categories")) }
    }

    private static func state(for categories: [OnDemandKind: [OnDemandCategory]]) -> CatalogState {
        categories.values.allSatisfy(\.isEmpty) ? .empty : .ready
    }

    // MARK: Shelves

    static func shelfKey(_ kind: OnDemandKind, _ categoryID: String) -> String {
        kind.rawValue + "|" + categoryID
    }

    func titles(_ kind: OnDemandKind, in categoryID: String) -> [OnDemandTitle]? {
        shelves[Self.shelfKey(kind, categoryID)]
    }

    func loadShelf(_ kind: OnDemandKind, categoryID: String, force: Bool = false) {
        let key = Self.shelfKey(kind, categoryID)
        guard let profileID, shelfLoads[key] != .loading,
              force || !validatedShelves.contains(key) else { return }
        shelfLoads[key] = .loading
        let generation = generation
        let file = Self.cacheURL(profileID, "\(kind.rawValue)-\(Self.fileSafe(categoryID))")
        Task { [weak self] in
            guard let self else { return }
            if self.shelves[key] == nil,
               let cached: [OnDemandTitle] = await Task.detached(operation: { Self.read(file) }).value,
               generation == self.generation {
                self.shelves[key] = cached
            }
            guard let client = self.client() else { self.shelfLoads[key] = .failed; return }
            do {
                let list = try await self.gated { try await client.onDemandTitles(kind, categoryID: categoryID) }
                guard generation == self.generation else { return }
                // A panel that ignores `category_id` answers with everything.
                let mine = list.filter { $0.categoryIDs.isEmpty || $0.categoryIDs.contains(categoryID) }
                self.shelves[key] = mine
                self.shelfLoads[key] = .loaded
                self.validatedShelves.insert(key)
                Task.detached(priority: .utility) { Self.write(mine, to: file) }
            } catch {
                guard generation == self.generation else { return }
                // A shelf drawn from the cache is still worth showing.
                self.shelfLoads[key] = self.shelves[key] == nil ? .failed : .loaded
            }
        }
    }

    // MARK: Search

    func loadSearchIndex(_ kind: OnDemandKind) {
        guard let profileID, searchLoads[kind] != .loading, !validatedSearch.contains(kind) else { return }
        searchLoads[kind] = .loading
        let generation = generation
        let file = Self.cacheURL(profileID, "\(kind.rawValue)-all")
        Task { [weak self] in
            guard let self else { return }
            if self.searchEntries[kind] == nil,
               let cached = await Task.detached(operation: { () -> [OnDemandSearchEntry]? in
                   let titles: [OnDemandTitle]? = Self.read(file)
                   return titles.map { $0.map(OnDemandSearchEntry.init) }
               }).value,
               generation == self.generation {
                self.searchEntries[kind] = cached
                self.searchLoads[kind] = .loaded
            }
            guard let client = self.client() else { self.searchLoads[kind] = .failed; return }
            do {
                let list = try await self.gated { try await client.onDemandTitles(kind, categoryID: nil) }
                let entries = await Task.detached(priority: .userInitiated) {
                    list.map(OnDemandSearchEntry.init)
                }.value
                guard generation == self.generation else { return }
                self.searchEntries[kind] = entries
                self.searchLoads[kind] = .loaded
                self.validatedSearch.insert(kind)
                Task.detached(priority: .utility) { Self.write(list, to: file) }
            } catch {
                guard generation == self.generation else { return }
                self.searchLoads[kind] = self.searchEntries[kind] == nil ? .failed : .loaded
            }
        }
    }

    func search(_ kind: OnDemandKind, _ query: String) -> [OnDemandTitle] {
        OnDemandSearch.matches(searchEntries[kind] ?? [], query: query)
    }

    // MARK: Details

    func movieDetail(_ title: OnDemandTitle) async throws -> OnDemandMovieDetail {
        if let held = movieDetails[title.providerID] { return held }
        guard let client = client() else { throw OnDemandError.noProvider }
        let generation = generation
        let detail = try await gated { try await client.movieDetail(streamID: title.providerID) }
        if generation == self.generation { movieDetails[title.providerID] = detail }
        return detail
    }

    func seriesDetail(_ title: OnDemandTitle) async throws -> OnDemandSeriesDetail {
        if let held = seriesDetails[title.providerID] { return held }
        guard let client = client() else { throw OnDemandError.noProvider }
        let generation = generation
        let detail = try await gated { try await client.seriesDetail(seriesID: title.providerID) }
        if generation == self.generation { seriesDetails[title.providerID] = detail }
        return detail
    }

    // MARK: Playback

    func playbackURLs(for record: OnDemandPlayback) -> [URL] {
        client()?.onDemandURL(record.kind, streamID: record.streamID,
                              containerExtension: record.containerExtension).map { [$0] } ?? []
    }

    var continueWatching: [OnDemandPlayback] {
        OnDemandProgressPolicy.continueWatching(playbacks.values)
    }

    func record(_ kind: OnDemandPlayback.Kind, _ streamID: String) -> OnDemandPlayback? {
        playbacks[OnDemandPlayback.key(kind, streamID)]
    }

    func resumePosition(_ kind: OnDemandPlayback.Kind, _ streamID: String) -> TimeInterval? {
        OnDemandProgressPolicy.resumePosition(record(kind, streamID))
    }

    func isWatched(_ kind: OnDemandPlayback.Kind, _ streamID: String) -> Bool {
        record(kind, streamID)?.completed == true
    }

    /// What a player reports as it goes. `profileID` is the provider the title
    /// was opened under, so a report that outlives a switch cannot land in
    /// the next provider's history.
    func track(_ template: OnDemandPlayback, profileID: UUID?, position: TimeInterval,
               duration: TimeInterval, upNext: OnDemandPlayback?) {
        guard let profileID, profileID == self.profileID, duration > 0 else { return }
        let completed = LocalMediaTrackingPolicy.isComplete(position: position, duration: duration)
        playbacks = OnDemandProgressPolicy.recording(template, position: position, duration: duration,
                                                     completed: completed, upNext: upNext,
                                                     now: Date(), in: playbacks)
        persistPlaybacks()
    }

    func setWatched(_ watched: Bool, _ template: OnDemandPlayback, upNext: OnDemandPlayback?) {
        guard profileID != nil else { return }
        playbacks = OnDemandProgressPolicy.marking(template, watched: watched, upNext: upNext,
                                                   now: Date(), in: playbacks)
        persistPlaybacks()
    }

    func removeFromContinueWatching(_ record: OnDemandPlayback) {
        playbacks = OnDemandProgressPolicy.removingFromContinueWatching(record.groupKey, in: playbacks)
        persistPlaybacks()
    }

    func clearHistory() {
        playbacks = [:]
        persistPlaybacks()
    }

    private func restorePlaybacks(profileID: UUID) {
        guard let data = defaults.data(forKey: playbackKey + "." + profileID.uuidString),
              let list = try? JSONDecoder().decode([OnDemandPlayback].self, from: data) else { return }
        playbacks = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
    }

    private func persistPlaybacks() {
        guard let profileID else { return }
        let key = playbackKey + "." + profileID.uuidString
        if playbacks.isEmpty { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(Array(playbacks.values)) { defaults.set(data, forKey: key) }
    }

    // MARK: Plumbing

    private func client() -> XtreamClient? {
        guard let profile, let password = KeychainStore.password(profileID: profile.id) else { return nil }
        return XtreamClient(profile: profile, password: password)
    }

    private func gated<T>(_ work: () async throws -> T) async throws -> T {
        if requestsInFlight < maximumConcurrentRequests {
            requestsInFlight += 1
        } else {
            // The slot is handed over by the request that finishes, still
            // counted, so a newcomer cannot slip in between.
            await withCheckedContinuation { waitingRequests.append($0) }
        }
        defer {
            if waitingRequests.isEmpty { requestsInFlight -= 1 }
            else { waitingRequests.removeFirst().resume() }
        }
        return try await work()
    }

    nonisolated private static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    nonisolated private static func cacheURL(_ profileID: UUID, _ name: String) -> URL {
        cacheDirectory().appendingPathComponent("lineup-ondemand-\(profileID.uuidString)-\(name).json")
    }

    nonisolated private static func fileSafe(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }

    nonisolated private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    enum OnDemandError: LocalizedError {
        case noProvider
        var errorDescription: String? { "Connect an IPTV provider to browse its on-demand titles." }
    }
}
