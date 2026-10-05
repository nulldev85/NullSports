import Foundation

/// What one connected server has put in the Library, and how its last load
/// went. Every server keeps its own, so one that is slow or offline costs the
/// Library that server's shelves and never another's.
struct MediaServerState {
    /// The server's own libraries, as `/views` reports them.
    var roots: [MediaItem] = []
    /// Collections, which on a Nullfin server is where an enabled addon catalog
    /// lands. Kept apart from `roots` only so the shelf picker can say which is
    /// which; a shelf made from either behaves the same way.
    var collections: [MediaItem] = []
    /// Collections named by the addons themselves, resolved one id at a time.
    ///
    /// The list of every collection is a broad query with a lot of assumptions
    /// in it. An addon says outright which catalogs it has switched on and what
    /// each one's collection is, and asking for one item by its id is the
    /// narrowest question there is. Where the two disagree this one is right,
    /// so both are merged and this one is the reason a catalog appears at all
    /// when the broad query comes back short.
    var importedCatalogs: [MediaItem] = []
    /// This server's shelves, in the order they were added.
    var catalogs: [MediaCatalog] = []
    var counts: MediaLibraryCounts?
    var refreshedAt: Date?
    var isConnected = false
    var isLoading = false
    /// Set when the last attempt ended without shelves, so the tab can say so
    /// and offer to try again instead of claiming there is nothing to show.
    var loadFailed = false
    /// The shelves on screen are this launch's answer from the server, rather
    /// than the snapshot put up before it was asked.
    var isLoaded = false
    /// Catalogs each addon offers that the server is not importing yet. Loaded
    /// on demand, because the routes behind it are administrator-only and a
    /// server may refuse them.
    var addonGroups: [MediaLibrary.AddonCatalogGroup] = []
    /// Set when the server will not discuss addons with this account, so the
    /// screen can say why rather than showing an empty list.
    var addonsUnavailable = false
}

@MainActor
final class MediaLibrary: ObservableObject {
    /// Every connected server, in the order they were added.
    ///
    /// All of them feed the Library at once: shelves, search and the streams
    /// for a title are drawn from each. Everything a server hands back is
    /// marked with the server it came from (`MediaItem.serverID`), so whatever
    /// is done with it later -- its page, its artwork, playing it -- goes back
    /// to that server.
    @Published private(set) var profiles: [MediaServerProfile] = []
    @Published private(set) var servers: [UUID: MediaServerState] = [:]
    /// MDBList shelves belong to the Library rather than to any one server:
    /// each list is matched against every server's titles together.
    @Published private(set) var mdbListShelves: [MediaCatalog] = []
    /// Shelves of the IPTV provider's categories, as chosen.
    @Published private(set) var providerShelves: [MediaCatalog] = []
    /// The shelf driving the large Library feature card.
    @Published private(set) var selectedHeroCatalogID: String? = nil
    /// Catalogs switched on and waiting for their server to finish importing,
    /// by server and catalog.
    @Published private(set) var importing: Set<String> = []
    @Published private(set) var isAddingServer = false
    private var importTasks: [String: Task<Void, Never>] = [:]

    /// MDBList is an account-level discovery integration. Lists are offered in
    /// Add Shelf, then matched to titles that the connected media servers can
    /// actually play.
    @Published private(set) var mdbListAccount: MDBListAccount?
    @Published private(set) var mdbListCatalogs: [MDBListCatalog] = []
    @Published private(set) var isMDBListConnected = false
    @Published private(set) var isMDBListLoading = false
    private var hasLoadedMDBListIntegration = false
    private var mdbListLoad: Task<Void, Never>?

    @Published var errorMessage: String?

    /// Playback state owned by this device. It deliberately does not travel
    /// through CloudSettingsSync: "local" means a shared Apple TV and a phone
    /// can keep separate places without surprising one another.
    @Published private(set) var localPlayback: [LocalMediaPlayback] = []
    @Published private(set) var localFavorites: [LocalMediaFavorite] = []

    private let defaults: UserDefaults
    // Named for the app's old name on purpose: this is where existing installs
    // already keep their data, and renaming the key would hide it from them.
    private let profilesKey = "NullSports.mediaServers"
    private let activeKey = "NullSports.activeMediaServer"
    private let deviceKey = "NullSports.mediaDeviceID"
    private let shelvesKey = "NullSports.mediaShelves"
    private let localPlaybackKey = "Lineup.localMediaPlayback.v1"
    private let localFavoritesKey = "Lineup.localMediaFavorites.v1"
    private let mdbListShelvesKey = "Lineup.mdbListShelves.v1"
    private let providerShelvesKey = "Lineup.providerShelves.v1"
    private let heroCatalogKey = "Lineup.mediaHeroCatalog.v1"
    /// The entry, in the stores that used to keep one per server, for a choice
    /// that is now the whole Library's.
    private static let libraryWide = "library"
    // Written by a version that could install media sources the app talked to
    // directly. That feature is gone, so the state it left behind is cleared
    // on the next launch rather than sitting in defaults forever.
    private static let retiredKeys = ["Lineup.stremioAddons", "Lineup.stremioShelves"]
    /// The newest load of each server. An older one that finishes late leaves
    /// the newer one's answer alone.
    private var loadIDs: [UUID: UUID] = [:]
    /// The load the Library asked for. It belongs to the store rather than to
    /// the tab: a load owned by a view's task is cancelled the moment the
    /// viewer looks at another tab, which is most of a slow one.
    private var libraryLoad: Task<Void, Never>?
    private var reconciledSeriesServers: Set<UUID> = []
    private var seriesReconcileTasks: [UUID: Task<Void, Never>] = [:]
    /// One client per server. Making one reads its token from the Keychain,
    /// and every poster on screen asks for one.
    private var clients: [UUID: JellyfinClient] = [:]
    /// A successful Library is restored before the network is touched on the
    /// next launch. The refresh still runs, but it replaces a useful screen
    /// instead of a spinner.
    private struct LibrarySnapshot: Codable, Sendable {
        let roots: [MediaItem]
        let collections: [MediaItem]
        let importedCatalogs: [MediaItem]
        let catalogs: [MediaCatalog]
        let counts: MediaLibraryCounts?
        let refreshedAt: Date
    }
    private struct CachedDetail {
        let item: MediaItem
        let storedAt: Date
    }
    private var detailCache: [String: CachedDetail] = [:]
    private struct CachedCounterpart {
        let item: MediaItem?
        let storedAt: Date
    }
    /// Each title's copy on each other server, once found, so playing it
    /// again does not search again.
    private var counterparts: [String: CachedCounterpart] = [:]
    /// Which kind of server each one is, as it said when first asked.
    private var serverKinds: [UUID: MediaServerKind] = [:]
    /// The IPTV provider's films and shows: one more place a title's streams
    /// can come from.
    let providerVOD: ProviderVOD

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        providerVOD = ProviderVOD(defaults: defaults)
        isMDBListConnected = MDBListKeychainStore.apiKey() != nil
        if let data = defaults.data(forKey: profilesKey),
           let saved = try? JSONDecoder().decode([MediaServerProfile].self, from: data) {
            profiles = saved
        }
        if let data = defaults.data(forKey: localPlaybackKey),
           let saved = try? JSONDecoder().decode([LocalMediaPlayback].self, from: data) {
            localPlayback = saved.map { Self.marked($0) }
        }
        if let data = defaults.data(forKey: localFavoritesKey),
           let saved = try? JSONDecoder().decode([LocalMediaFavorite].self, from: data) {
            localFavorites = saved.map { Self.marked($0) }
        }
        let listsRestored = restoreMDBListSnapshot()
        let formerActive = formerActiveServer()
        for profile in profiles {
            restoreLibrarySnapshot(for: profile, adoptingLists: !listsRestored && profile.id == formerActive)
        }
        migrateLibraryChoices()
        selectedHeroCatalogID = savedHeroCatalogs()[Self.libraryWide]
        for key in Self.retiredKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    var hasProfile: Bool { !profiles.isEmpty }

    /// Whether there is anything to show at all.
    var hasAnySource: Bool { !profiles.isEmpty }

    // MARK: - The Library across every server

    var roots: [MediaItem] { profiles.flatMap { servers[$0.id]?.roots ?? [] } }
    var collections: [MediaItem] { profiles.flatMap { servers[$0.id]?.collections ?? [] } }
    var importedCatalogs: [MediaItem] { profiles.flatMap { servers[$0.id]?.importedCatalogs ?? [] } }

    /// Every shelf: each server's, servers in the order they were added, then
    /// the MDBList shelves that draw on all of them.
    var catalogs: [MediaCatalog] {
        profiles.flatMap { servers[$0.id]?.catalogs ?? [] } + mdbListShelves + providerShelves
    }

    var addonGroups: [AddonCatalogGroup] { profiles.flatMap { servers[$0.id]?.addonGroups ?? [] } }

    var addonsUnavailable: Bool {
        !profiles.isEmpty && profiles.allSatisfy { servers[$0.id]?.addonsUnavailable == true }
    }

    /// Every server's counts together. A server that has not reported yet is
    /// left out rather than counted as empty, and nothing reported is nil.
    var libraryCounts: MediaLibraryCounts? {
        let known = profiles.compactMap { servers[$0.id]?.counts }
        guard !known.isEmpty else { return nil }
        return MediaLibraryCounts(movies: known.map(\.movies).reduce(0, +),
                                  shows: known.map(\.shows).reduce(0, +),
                                  episodes: known.map(\.episodes).reduce(0, +))
    }

    var lastRefreshedAt: Date? { profiles.compactMap { servers[$0.id]?.refreshedAt }.max() }
    var isConnected: Bool { profiles.contains { servers[$0.id]?.isConnected == true } }
    var isLoading: Bool { isAddingServer || profiles.contains { servers[$0.id]?.isLoading == true } }

    /// Every server's last attempt failed: there is nothing fresh to show.
    var loadFailed: Bool {
        !profiles.isEmpty && profiles.allSatisfy { servers[$0.id]?.loadFailed == true }
    }

    func state(of profile: MediaServerProfile) -> MediaServerState {
        servers[profile.id] ?? MediaServerState()
    }

    /// A server's name, for showing beside what it offers -- but only when
    /// there is more than one server to tell apart.
    func serverName(of serverID: UUID?) -> String? {
        guard let serverID else { return nil }
        // The provider's shelves are always named: they sit among the servers'.
        if let provider = providerVOD.profile, provider.id == serverID { return provider.name }
        guard profiles.count > 1 else { return nil }
        return profiles.first { $0.id == serverID }?.name
    }

    func serverName(for catalog: MediaCatalog) -> String? { serverName(of: catalog.root.serverID) }

    /// A shelf's name where a list of every shelf shows it: with more than one
    /// server, two of them can each have a "Movies".
    func shelfName(_ catalog: MediaCatalog) -> String {
        serverName(for: catalog).map { catalog.title + " · " + $0 } ?? catalog.title
    }

    /// In-progress titles, newest first. A completed title belongs in History,
    /// not in Continue Watching, even if its final saved position is shy of the
    /// exact file duration.
    var continueWatching: [LocalMediaPlayback] {
        let candidates = playbackForConnectedServers.filter {
            !$0.completed && ($0.isUpNext == true
                || ($0.explicitlyUnwatched != true && $0.position >= 5))
        }
        // One show should occupy one place in Continue Watching. A genuine
        // resume point is the current episode and must not be displaced by a
        // newer generated Up Next record from the same series.
        var selected: [String: LocalMediaPlayback] = [:]
        for record in candidates {
            let key = record.profileID.uuidString + "|" + (record.item.type == "Episode"
                ? "series:" + Self.seriesKey(for: record.item)
                : "item:" + record.item.id)
            if let existing = selected[key] {
                if Self.prefersForDisplay(record, over: existing) { selected[key] = record }
            } else {
                selected[key] = record
            }
        }
        return selected.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Finished titles stay useful as a short, local history without taking
    /// over the Library. The stored collection itself is capped as well.
    var watchHistory: [LocalMediaPlayback] {
        playbackForConnectedServers.filter(\.completed).sorted { $0.updatedAt > $1.updatedAt }
    }

    var favoriteMedia: [MediaItem] {
        let connected = recordSources
        return localFavorites.filter { connected.contains($0.profileID) }
            .sorted { $0.addedAt > $1.addedAt }.map(\.item)
    }

    /// Every row on the Media Servers tab.
    var shelves: [MediaCatalog] { catalogs }

    /// A missing or removed choice falls back to the first populated shelf.
    /// That keeps the hub useful immediately while leaving the actual saved
    /// choice untouched until the viewer deliberately picks one.
    var heroCatalog: MediaCatalog? {
        MediaHeroCatalogSelection.resolve(catalogs, selectedID: selectedHeroCatalogID)
    }

    func selectHeroCatalog(_ catalog: MediaCatalog) {
        guard catalogs.contains(where: { $0.id == catalog.id }) else { return }
        selectedHeroCatalogID = catalog.id
        saveHeroCatalogID(catalog.id)
    }

    // MARK: - Servers

    func addServer(name: String, serverURL: String, username: String, password: String) async -> Bool {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the user name is required. A Jellyfin-compatible server may have
        // no password set on the account, and the server itself is the right
        // judge of whether the credentials it was handed are good enough.
        guard !cleanUsername.isEmpty else {
            errorMessage = "Enter your media server user name."
            return false
        }
        isAddingServer = true
        errorMessage = nil
        defer { isAddingServer = false }
        do {
            let client = try JellyfinClient(serverURL: serverURL, deviceID: deviceID)
            let authentication = try await client.authenticate(username: cleanUsername, password: password)
            let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = client.serverURL.absoluteString
            var profile = MediaServerProfile(
                name: typedName.isEmpty ? "My Media" : typedName,
                serverURL: address,
                username: authentication.user.name,
                userID: authentication.user.id
            )
            // Signing in again to a server that is already here is a new token
            // for it, not a second copy of every one of its shelves.
            let existing = profiles.firstIndex { $0.serverURL == address && $0.userID == authentication.user.id }
            if let existing {
                profile = MediaServerProfile(id: profiles[existing].id,
                    name: typedName.isEmpty ? profiles[existing].name : typedName,
                    serverURL: address, username: authentication.user.name,
                    userID: authentication.user.id)
            }
            try MediaKeychainStore.save(token: authentication.accessToken, profileID: profile.id)
            clients[profile.id] = nil
            serverKinds[profile.id] = nil
            if let existing {
                profiles[existing] = profile
            } else {
                profiles.append(profile)
                servers[profile.id] = MediaServerState()
            }
            persist()
            // Its shelves before the sheet closes, so the Library already has
            // them. What spans every server follows behind.
            await loadServer(profile)
            Task { [weak self] in
                await self?.loadMDBListShelves()
                await self?.loadAddonCatalogs(on: [profile])
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ profile: MediaServerProfile) {
        loadIDs[profile.id] = nil
        seriesReconcileTasks[profile.id]?.cancel()
        seriesReconcileTasks[profile.id] = nil
        reconciledSeriesServers.remove(profile.id)
        for (key, task) in importTasks where key.hasPrefix(profile.id.uuidString) { task.cancel() }
        MediaKeychainStore.delete(profileID: profile.id)
        clients[profile.id] = nil
        serverKinds[profile.id] = nil
        profiles.removeAll { $0.id == profile.id }
        servers[profile.id] = nil
        localPlayback.removeAll { $0.profileID == profile.id }
        persistLocalPlayback()
        localFavorites.removeAll { $0.profileID == profile.id }
        persistLocalFavorites()
        var shelfChoices = savedShelves()
        if shelfChoices.removeValue(forKey: profile.id.uuidString) != nil {
            defaults.set(try? JSONEncoder().encode(shelfChoices), forKey: shelvesKey)
        }
        try? FileManager.default.removeItem(at: Self.snapshotURL(profileID: profile.id))
        // Its titles leave the MDBList shelves with it; the lists stay.
        mdbListShelves = mdbListShelves.map { shelf in
            MediaCatalog(root: shelf.root, items: shelf.items.filter { $0.serverID != profile.id })
        }
        persistMDBListSnapshot()
        if selectedHeroCatalogID?.hasPrefix(profile.id.uuidString + "|") == true {
            selectedHeroCatalogID = nil
            saveHeroCatalogID(nil)
        }
        detailCache = detailCache.filter { !$0.key.hasPrefix(profile.id.uuidString) }
        counterparts = counterparts.filter { !$0.key.contains(profile.id.uuidString) }
        persist()
    }

    /// What the Media Servers tab asks for when it appears.
    ///
    /// Not `await`ed from the tab, and deliberately: the load is several
    /// requests deep and a viewer who switches tabs while it runs used to
    /// cancel it, come back, and find the work neither finished nor running.
    /// The store holds the task instead, so looking away costs nothing and
    /// looking back finds it done.
    ///
    /// It starts nothing for a server whose shelves are already loaded, and
    /// starts again for one whose attempt failed, which is the retry a viewer
    /// would otherwise have to find in a menu.
    func loadShelvesIfNeeded() {
        guard !profiles.isEmpty else { return }
        for profile in profiles { reconcileSeriesPositionsIfNeeded(for: profile) }
        guard libraryLoad == nil else { return }
        let due = profiles.filter { profile in
            let current = self.state(of: profile)
            return MediaShelfLoad.shouldStart(profile: profile.id,
                                              loaded: current.isLoaded ? profile.id : nil,
                                              alreadyRunning: false,
                                              lastAttemptFailed: current.loadFailed)
        }
        guard !due.isEmpty else { return }
        libraryLoad = Task { [weak self] in
            await self?.reload(servers: due)
            self?.libraryLoad = nil
        }
    }

    func reload() async {
        await reload(servers: profiles)
    }

    /// Fresh shelves from each of `targets` at once, then the shelves and
    /// catalogs that are drawn from them.
    private func reload(servers targets: [MediaServerProfile]) async {
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for profile in targets {
                group.addTask { await self.loadServer(profile) }
            }
        }
        // After the libraries, not before: MDBList is a request per list over
        // every server's titles, and the addon catalogs a request per enabled
        // catalog. The shelves should not wait behind either.
        await loadMDBListShelves()
        await loadAddonCatalogs(on: targets)
    }

    /// One server's libraries and shelves.
    ///
    /// Its failure is its own: every other server's shelves stay up, and this
    /// one keeps whatever it showed last.
    private func loadServer(_ profile: MediaServerProfile) async {
        let requestID = UUID()
        loadIDs[profile.id] = requestID
        let isCurrent = { [unowned self] in
            self.loadIDs[profile.id] == requestID && self.contains(profile)
        }
        update(profile) { $0.isLoading = true }
        do {
            let source = try client(for: profile)
            let loaded = try await source.views(userID: profile.userID).map { $0.servedBy(profile.id) }
            // A server with no collections answers with an empty list, and one
            // too old to know the route answers an error. Neither is worth
            // costing the viewer the libraries that did load.
            // The BoxSet filter matches on the server's own kind, not on the
            // type it reports, so a promoted collection comes back here as well
            // as in the views above. Whatever a library already offers is the
            // library's.
            let known = Set(loaded.map(\.id))
            let loadedCollections = ((try? await source.allCollections(userID: profile.userID)) ?? [])
                .filter { !known.contains($0.id) }
                .map { $0.servedBy(profile.id) }
            let selectedRoots = selectedShelfRoots(from: loaded + loadedCollections, profileID: profile.id)
            let coldStart = state(of: profile).catalogs.isEmpty
            let loadedCatalogs = await withTaskGroup(of: (Int, MediaCatalog).self) { group in
                for (index, root) in selectedRoots.enumerated() {
                    group.addTask {
                        let items = (try? await source.items(userID: profile.userID, parentID: root.id)) ?? []
                        return (index, MediaCatalog(root: root, items: items.map { $0.servedBy(profile.id) }))
                    }
                }
                var result: [Int: MediaCatalog] = [:]
                for await (index, catalog) in group {
                    result[index] = catalog
                    // On a device with no snapshot yet, reveal the first real
                    // shelf as soon as it arrives. Later results are committed
                    // together so a normal refresh does not repeatedly rebuild
                    // the screen.
                    if coldStart, isCurrent(), state(of: profile).catalogs.isEmpty, !catalog.items.isEmpty {
                        update(profile) { state in
                            state.roots = loaded
                            state.collections = loadedCollections
                            state.catalogs = [catalog]
                        }
                    }
                }
                return result.keys.sorted().compactMap { result[$0] }
            }
            guard isCurrent() else { return }
            update(profile) { state in
                state.roots = loaded
                state.collections = loadedCollections
                state.catalogs = loadedCatalogs
                state.isConnected = true
                state.isLoading = false
                state.loadFailed = false
                state.isLoaded = true
                state.refreshedAt = Date()
            }
            persistLibrarySnapshot(for: profile)
            Task { [weak self] in
                let counts = try? await source.libraryCounts(userID: profile.userID)
                guard let self, self.loadIDs[profile.id] == requestID else { return }
                self.update(profile) { $0.counts = counts }
                self.persistLibrarySnapshot(for: profile)
            }
        } catch {
            guard isCurrent() else { return }
            // A cancelled load is the app's own bookkeeping, not a fault: a
            // second refresh replaces the first, and leaving a tab cancels what
            // it started. Reporting it put an alert reading "cancelled" in
            // front of a viewer who had simply opened the tab, and marked a
            // server offline that was never asked.
            //
            // It is still a load that stopped, though, and returning here
            // without saying so left the flag raised with nothing running
            // behind it -- the tab reading "Loading libraries…" for the rest
            // of the session, and every later attempt declining to start
            // because one was apparently already under way.
            let cancelled = Self.isCancellation(error)
            if !cancelled { report(error, from: profile) }
            update(profile) { state in
                if !cancelled { state.isConnected = false }
                state.loadFailed = true
                state.isLoading = false
            }
        }
    }

    // MARK: - Titles

    func items(in parent: MediaItem) async throws -> [MediaItem] {
        if let place = ProviderItem(id: parent.id), let provider = parent.serverID {
            return try await providerChildren(of: place, provider: provider)
        }
        if Self.isMDBListShelfID(parent.id) {
            return catalogs.first { $0.id == parent.id }?.items ?? []
        }
        guard let profile = profile(for: parent) else { return [] }
        return try await client(for: profile).items(userID: profile.userID, parentID: parent.id)
            .map { $0.servedBy(profile.id) }
    }

    // Seasons and episodes are numbered, not named: "Season 10" sorts before
    // "Season 2" by name. A season can also run long past the shelf's limit.
    func numberedChildren(of parent: MediaItem) async throws -> [MediaItem] {
        if let place = ProviderItem(id: parent.id), let provider = parent.serverID {
            return try await providerChildren(of: place, provider: provider)
        }
        guard let profile = profile(for: parent) else { return [] }
        return try await client(for: profile).items(userID: profile.userID,
            parentID: parent.id, sortBy: "IndexNumber", limit: 500)
            .map { $0.servedBy(profile.id) }
    }

    /// The full record for an item. A shelf card carries only what a shelf needs.
    func details(of item: MediaItem) async throws -> MediaItem {
        if ProviderItem(id: item.id) != nil { return await providerDetails(of: item) }
        guard let profile = profile(for: item) else { return item }
        let key = profile.id.uuidString + "|" + item.id
        if let cached = detailCache[key], Date().timeIntervalSince(cached.storedAt) < 600 {
            return cached.item
        }
        let detailed = try await client(for: profile).item(userID: profile.userID, itemID: item.id)
            .servedBy(profile.id)
        detailCache[key] = CachedDetail(item: detailed, storedAt: Date())
        return detailed
    }

    func related(to item: MediaItem) async -> [MediaItem] {
        let genres = Set((item.genres ?? []).map { $0.lowercased() })
        let local = shelves.flatMap(\.items).filter { candidate in
            candidate.hasDetailPage && candidate.type == item.type
                && candidate.libraryKey != item.libraryKey
                && !genres.isEmpty
                && !genres.isDisjoint(with: Set((candidate.genres ?? []).map { $0.lowercased() }))
        }.sorted { left, right in
            let leftMatch = genres.intersection(Set((left.genres ?? []).map { $0.lowercased() })).count
            let rightMatch = genres.intersection(Set((right.genres ?? []).map { $0.lowercased() })).count
            return leftMatch > rightMatch
        }
        var remote: [MediaItem] = []
        if let profile = profile(for: item) {
            remote = (try? await client(for: profile)
                .similarItems(userID: profile.userID, itemID: item.id))?
                .filter { $0.id != item.id && $0.hasDetailPage }
                .map { $0.servedBy(profile.id) } ?? []
        }
        // Server recommendations can be empty or unavailable. Shelved movies
        // of matching genres keep the Related row useful on either platform.
        var seen: Set<String> = []
        return (remote + local).filter { candidate in
            let key = "\(candidate.name.lowercased())|\(candidate.productionYear ?? 0)"
            return seen.insert(key).inserted
        }.prefix(16).map { $0 }
    }

    /// A cast member's portrait, from the server that described them.
    func personImageURL(for person: MediaPerson, of item: MediaItem, width: Int = 300) -> URL? {
        guard person.primaryImageTag != nil, let personID = person.personID,
              let profile = profile(for: item) else { return nil }
        return try? client(for: profile)
            .imageURL(itemID: personID, type: "primary", maxWidth: width)
    }

    func nextUp(in series: MediaItem) async -> MediaItem? {
        guard let profile = profile(for: series) else { return nil }
        let next = try? await client(for: profile)
            .nextUp(userID: profile.userID, seriesID: series.id).first
        return next?.servedBy(profile.id)
    }

    /// Per-source scores, when the server keeps them. A Jellyfin server does
    /// not, so a failure here means "show what the item itself carries".
    func metrics(for item: MediaItem) async -> [MediaMetric] {
        guard let profile = profile(for: item) else { return [] }
        return (try? await client(for: profile).itemMetrics(itemID: item.id)) ?? []
    }

    func setFavorite(_ isFavorite: Bool, for item: MediaItem) async {
        guard let profile = profile(for: item) else { return }
        do {
            try await client(for: profile)
                .setFavorite(userID: profile.userID, itemID: item.id, isFavorite: isFavorite)
        } catch {
            report(error, from: profile)
        }
    }

    func setPlayed(_ isPlayed: Bool, for item: MediaItem) async {
        guard let profile = profile(for: item) else { return }
        do {
            try await client(for: profile)
                .setPlayed(userID: profile.userID, itemID: item.id, isPlayed: isPlayed)
        } catch {
            report(error, from: profile)
        }
    }

    // MARK: - MDBList integration

    func connectMDBList(apiKey: String) async -> Bool {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            errorMessage = MDBListError.missingAPIKey.localizedDescription
            return false
        }
        isMDBListLoading = true
        defer { isMDBListLoading = false }
        do {
            let source = MDBListClient(apiKey: cleanKey)
            async let account = source.account()
            async let lists = source.catalogChoices()
            let loadedAccount = try await account
            let loadedLists = try await lists
            try MDBListKeychainStore.save(apiKey: cleanKey)
            mdbListAccount = loadedAccount
            mdbListCatalogs = loadedLists
            isMDBListConnected = true
            hasLoadedMDBListIntegration = true
            errorMessage = nil
            if !savedMDBListShelfIDs().isEmpty { await loadMDBListShelves() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadMDBListIntegration() async {
        guard let apiKey = MDBListKeychainStore.apiKey() else {
            isMDBListConnected = false
            mdbListAccount = nil
            mdbListCatalogs = []
            return
        }
        guard !isMDBListLoading else { return }
        isMDBListLoading = true
        defer { isMDBListLoading = false }
        do {
            let source = MDBListClient(apiKey: apiKey)
            async let account = source.account()
            async let lists = source.catalogChoices()
            mdbListAccount = try await account
            mdbListCatalogs = try await lists
            isMDBListConnected = true
        } catch {
            // A saved key still represents a configured integration. Keep it
            // connected during a temporary outage and surface the refresh
            // failure without throwing away the account.
            isMDBListConnected = true
            errorMessage = error.localizedDescription
        }
    }

    /// Account screens can appear repeatedly as the viewer changes tabs. The
    /// integration belongs to the store, so load it once per launch and let an
    /// explicit Refresh action handle later updates instead of issuing two
    /// network requests on every visit.
    func loadMDBListIntegrationIfNeeded() {
        guard isMDBListConnected, !hasLoadedMDBListIntegration,
              mdbListLoad == nil else { return }
        mdbListLoad = Task { [weak self] in
            guard let self else { return }
            await self.loadMDBListIntegration()
            self.hasLoadedMDBListIntegration = true
            self.mdbListLoad = nil
        }
    }

    func disconnectMDBList() {
        mdbListLoad?.cancel()
        mdbListLoad = nil
        hasLoadedMDBListIntegration = false
        MDBListKeychainStore.delete()
        mdbListAccount = nil
        mdbListCatalogs = []
        isMDBListConnected = false
        errorMessage = nil
        mdbListShelves = []
        defaults.removeObject(forKey: mdbListShelvesKey)
        persistMDBListSnapshot()
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    var availableMDBListCatalogs: [MDBListCatalog] {
        mdbListCatalogs.filter { list in !mdbListShelves.contains(where: { $0.id == list.shelfID }) }
    }

    func addMDBListShelf(_ list: MDBListCatalog) async {
        guard !profiles.isEmpty, let apiKey = MDBListKeychainStore.apiKey(),
              !mdbListShelves.contains(where: { $0.id == list.shelfID }) else { return }
        do {
            async let entries = MDBListClient(apiKey: apiKey).items(in: list.id)
            async let titles = combinedInventory()
            let inventory = await titles
            if inventory.items.isEmpty, let failure = inventory.failure { throw failure }
            let matched = MDBListCatalogMatcher.match(try await entries, to: inventory.items)
            guard !mdbListShelves.contains(where: { $0.id == list.shelfID }) else { return }
            mdbListShelves.append(Self.mdbListShelf(list, items: matched))
            var ids = savedMDBListShelfIDs()
            if !ids.contains(list.id) { ids.append(list.id) }
            saveMDBListShelfIDs(ids)
            errorMessage = nil
            persistMDBListSnapshot()
        } catch {
            if !Self.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    /// The saved lists, each matched against every connected server's titles
    /// at once. A list that does not answer keeps the shelf it had.
    private func loadMDBListShelves() async {
        let selected = savedMDBListShelfIDs()
        guard !selected.isEmpty, let apiKey = MDBListKeychainStore.apiKey() else {
            if !mdbListShelves.isEmpty {
                mdbListShelves = []
                persistMDBListSnapshot()
            }
            return
        }
        guard !profiles.isEmpty else { return }
        do {
            let mdb = MDBListClient(apiKey: apiKey)
            let lists = try await mdb.catalogChoices()
            mdbListCatalogs = lists
            isMDBListConnected = true
            let inventory = await combinedInventory()
            if inventory.items.isEmpty, let failure = inventory.failure { throw failure }
            let titles = inventory.items
            let selectedLists = selected.compactMap { id in lists.first { $0.id == id } }
            let loaded = await withTaskGroup(of: MediaCatalog?.self) { group in
                for list in selectedLists {
                    group.addTask {
                        guard let entries = try? await mdb.items(in: list.id) else { return nil }
                        return Self.mdbListShelf(list, items: MDBListCatalogMatcher.match(entries, to: titles))
                    }
                }
                var shelves: [String: MediaCatalog] = [:]
                for await shelf in group {
                    if let shelf { shelves[shelf.id] = shelf }
                }
                return shelves
            }
            let previous = Dictionary(mdbListShelves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            mdbListShelves = selectedLists.compactMap { loaded[$0.shelfID] ?? previous[$0.shelfID] }
            persistMDBListSnapshot()
        } catch {
            // MDBList being unavailable must never take the connected media
            // servers or their own shelves down with it.
        }
    }

    /// Every connected server's films and shows, servers in the order they
    /// were added, with the first failure for when none of them answered.
    private func combinedInventory() async -> (items: [MediaItem], failure: Error?) {
        let targets = profiles.map { ($0, try? client(for: $0)) }
        let answers = await withTaskGroup(of: (Int, Result<[MediaItem], Error>).self) { group in
            for (index, (profile, source)) in targets.enumerated() {
                group.addTask {
                    guard let source else { return (index, .failure(JellyfinError.authenticationFailed)) }
                    do {
                        let titles = try await source.allTitles(userID: profile.userID)
                        return (index, .success(titles.map { $0.servedBy(profile.id) }))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var answers: [Int: Result<[MediaItem], Error>] = [:]
            for await (index, answer) in group { answers[index] = answer }
            return answers
        }
        var items: [MediaItem] = []
        var failure: Error?
        for index in targets.indices {
            switch answers[index] {
            case .success(let titles)?: items += titles
            case .failure(let error)?: if failure == nil { failure = error }
            case nil: break
            }
        }
        return (items, failure)
    }

    // MARK: - Local playback tracking

    func localPlaybackRecord(for item: MediaItem) -> LocalMediaPlayback? {
        guard let profileID = serverID(of: item) else { return nil }
        return localPlayback.first { $0.profileID == profileID && $0.item.id == item.id }
    }

    /// The progress a card should present. Films and episodes match directly;
    /// a series poster represents the active episode being watched in that
    /// show. Restored and genuine resume points outrank generated Up Next and
    /// completed history so the card always describes the viewer's real place.
    func displayedPlaybackRecord(for item: MediaItem) -> LocalMediaPlayback? {
        if let exact = localPlaybackRecord(for: item) {
            if exact.explicitlyUnwatched != true || exact.isUpNext == true { return exact }
            if !item.isSeries { return nil }
        }
        guard item.isSeries else { return nil }
        guard let profileID = serverID(of: item) else { return nil }
        var best: LocalMediaPlayback?
        for record in localPlayback where record.profileID == profileID {
            guard record.item.type == "Episode",
                  (record.explicitlyUnwatched != true || record.isUpNext == true) else { continue }
            let belongsToSeries: Bool
            if let seriesID = record.item.seriesID { belongsToSeries = seriesID == item.id }
            else { belongsToSeries = record.item.seriesName?
                .localizedCaseInsensitiveCompare(item.name) == .orderedSame }
            guard belongsToSeries else { continue }
            if let existing = best {
                if Self.prefersForDisplay(record, over: existing) { best = record }
            } else {
                best = record
            }
        }
        return best
    }

    nonisolated private static func displayPriority(_ record: LocalMediaPlayback) -> Int {
        if record.explicitlyUnwatched == true && record.isUpNext == true { return 0 }
        if !record.completed && record.isUpNext != true && record.position >= 5 { return 1 }
        if !record.completed && record.isUpNext == true { return 2 }
        if record.completed { return 3 }
        return 4
    }

    nonisolated private static func prefersForDisplay(_ candidate: LocalMediaPlayback,
                                                       over existing: LocalMediaPlayback) -> Bool {
        let candidatePriority = displayPriority(candidate)
        let existingPriority = displayPriority(existing)
        if candidatePriority != existingPriority { return candidatePriority < existingPriority }
        return candidate.updatedAt > existing.updatedAt
    }

    /// One consistent line under artwork throughout the Library.
    func playbackStatus(for item: MediaItem) -> String? {
        playbackStatus(for: item, record: displayedPlaybackRecord(for: item))
    }

    /// One lookup supplies every piece a shelf card needs. Keeping this work
    /// together matters when dozens of cards enter during a fast scroll: the
    /// older view independently searched tracking history for the progress
    /// line, the checkmark, and then the label again.
    func cardPlaybackPresentation(for item: MediaItem)
        -> (fraction: Double, label: String, watched: Bool)? {
        let record = displayedPlaybackRecord(for: item)
        if let record, record.completed || record.fraction > 0 || record.isUpNext == true,
           let label = playbackStatus(for: item, record: record) {
            return (record.completed ? 1 : record.fraction, label,
                    record.completed || item.isPlayed)
        }
        guard isWatched(item),
              let label = playbackStatus(for: item, record: record) else { return nil }
        return (1, label, true)
    }

    private func playbackStatus(for item: MediaItem, record: LocalMediaPlayback?) -> String? {
        guard let record else {
            // A server-supplied watched flag may predate local tracking. It
            // still deserves the same visible treatment as a locally watched
            // title instead of leaving the checkmark to carry the state alone.
            guard isWatched(item) else { return nil }
            return item.episodeCode.map { $0 + " · Watched" } ?? "Watched"
        }
        let trackedItem = record.item
        let episodePrefix: String? = trackedItem.type == "Episode"
            ? (trackedItem.episodeCode ?? "S01E01")
            : nil
        if record.completed {
            return episodePrefix.map { $0 + " · Watched" } ?? "Watched"
        }
        if record.isUpNext == true {
            return episodePrefix.map { $0 + " · Next Ep." } ?? "Next Ep."
        }
        let remaining = max(0, record.duration - record.position)
        let minutes = max(1, Int(ceil(remaining / 60)))
        let time: String
        if trackedItem.type == "Episode" {
            time = minutes == 1 ? "1 minute left" : "\(minutes) minutes left"
        } else if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            time = rest == 0 ? "\(hours)h remaining" : "\(hours)h \(rest)m remaining"
        } else {
            time = "\(minutes)m remaining"
        }
        return episodePrefix.map { $0 + " · " + time } ?? time
    }

    func resumePosition(for item: MediaItem) -> TimeInterval? {
        guard let record = localPlaybackRecord(for: item) else { return nil }
        return LocalMediaTrackingPolicy.resumePosition(for: record)
    }

    func trackPlayback(of item: MediaItem, position: TimeInterval, duration: TimeInterval) {
        guard let profileID = serverID(of: item), position.isFinite, duration.isFinite,
              position >= 0, duration > 0 else { return }

        let safePosition = min(position, duration)
        // A title only becomes history after somebody has genuinely started it.
        // This also prevents opening and immediately closing a stream from
        // displacing something the viewer was actually watching.
        guard safePosition >= 5 else { return }
        let completed = LocalMediaTrackingPolicy.isComplete(position: safePosition, duration: duration)
        let record = LocalMediaPlayback(profileID: profileID, item: item.servedBy(profileID),
            position: safePosition, duration: duration, updatedAt: Date(), completed: completed)
        let wasCompleted = localPlayback.first(where: { $0.id == record.id })?.completed == true
        if let index = localPlayback.firstIndex(where: { $0.id == record.id }) {
            localPlayback[index] = record
        } else {
            localPlayback.append(record)
        }
        // Keep plenty of useful history without letting artwork-rich item
        // records grow defaults forever. Each server retains its newest 200.
        let retained = Dictionary(grouping: localPlayback, by: \.profileID).values.flatMap { records in
            records.sorted { $0.updatedAt > $1.updatedAt }.prefix(200)
        }
        localPlayback = Array(retained)
        persistLocalPlayback()
        if item.type == "Episode", completed, !wasCompleted {
            Task { [weak self] in
                await self?.advanceAfterCompletedPlayback(item, profileID: profileID)
            }
        }
    }

    func clearLocalPlayback() {
        let connected = recordSources
        localPlayback.removeAll { connected.contains($0.profileID) }
        persistLocalPlayback()
    }

    func isInContinueWatching(_ item: MediaItem) -> Bool {
        let profileID = serverID(of: item)
        return continueWatching.contains { $0.profileID == profileID && $0.item.id == item.id }
    }

    /// Forget one resume point without telling the media server that the title
    /// was watched or unwatched. Playing it again naturally creates a fresh
    /// progress record.
    func removeFromContinueWatching(_ item: MediaItem) {
        guard let profileID = serverID(of: item) else { return }
        localPlayback.removeAll { $0.profileID == profileID && $0.item.id == item.id }
        persistLocalPlayback()
    }

    func isLocalFavorite(_ item: MediaItem) -> Bool {
        guard let profileID = serverID(of: item) else { return false }
        return localFavorites.contains { $0.profileID == profileID && $0.item.id == item.id }
    }

    func setLocalFavorite(_ favorite: Bool, for item: MediaItem) {
        guard let profileID = serverID(of: item) else { return }
        localFavorites.removeAll { $0.profileID == profileID && $0.item.id == item.id }
        if favorite {
            localFavorites.append(LocalMediaFavorite(profileID: profileID,
                item: item.servedBy(profileID), addedAt: Date()))
        }
        persistLocalFavorites()
    }

    func setLocallyPlayed(_ played: Bool, for item: MediaItem) {
        guard let profileID = serverID(of: item) else { return }
        localPlayback.removeAll { $0.profileID == profileID && $0.item.id == item.id }
        let duration = item.runTimeTicks.map { max(1, Double($0) / 10_000_000) } ?? 1
        localPlayback.append(LocalMediaPlayback(profileID: profileID, item: item.servedBy(profileID),
            position: played ? duration : 0, duration: duration, updatedAt: Date(),
            completed: played, explicitlyUnwatched: played ? nil : true))
        persistLocalPlayback()
    }

    /// Update an episode and keep Continue Watching pointed at the episode a
    /// viewer should play next. Generated Up Next records are distinct from
    /// genuine resume points, so rolling back never destroys real progress.
    func setEpisodePlayedAndAdvance(_ played: Bool, for episode: MediaItem) async {
        guard episode.type == "Episode", let profile = profile(for: episode) else {
            setLocallyPlayed(played, for: episode)
            await setPlayed(played, for: episode)
            return
        }

        let trackedEpisode: MediaItem
        if episode.seriesID == nil, let detailed = try? await details(of: episode) {
            trackedEpisode = detailed
        } else {
            trackedEpisode = episode
        }

        var following: MediaItem?
        if played {
            following = await followingUnwatchedEpisode(after: trackedEpisode, profile: profile)
        }
        guard contains(profile) else { return }
        applyLocalEpisodeProgression(played, for: trackedEpisode, following: following)
        await setPlayed(played, for: episode)
    }

    /// Internal for regression tests as well as the async server-backed path.
    func applyLocalEpisodeProgression(_ played: Bool, for episode: MediaItem,
                                      following: MediaItem?) {
        guard let profileID = serverID(of: episode) else { return }
        setLocallyPlayed(played, for: episode)
        let seriesKey = Self.seriesKey(for: episode)
        localPlayback.removeAll { record in
            record.profileID == profileID && record.isUpNext == true
                && Self.seriesKey(for: record.item) == seriesKey
        }

        if played {
            if let following { queueAsUpNext(following, explicitlyUnwatched: false) }
        } else {
            queueAsUpNext(episode, explicitlyUnwatched: true)
        }
        persistLocalPlayback()
    }

    /// A detail page gets the server's authoritative next episode while it is
    /// already loading. Remember it so every poster for that series shows the
    /// same useful position when the viewer returns to Library.
    func rememberNextUp(_ episode: MediaItem) {
        guard episode.type == "Episode", let profileID = serverID(of: episode) else { return }
        let key = Self.seriesKey(for: episode)
        let hasRealProgress = localPlayback.contains { record in
            record.profileID == profileID && Self.seriesKey(for: record.item) == key
                && !record.completed && record.isUpNext != true && record.position >= 5
                && record.explicitlyUnwatched != true
        }
        guard !hasRealProgress else { return }
        localPlayback.removeAll { record in
            record.profileID == profileID && record.isUpNext == true
                && Self.seriesKey(for: record.item) == key
        }
        queueAsUpNext(episode, explicitlyUnwatched: false)
        persistLocalPlayback()
    }

    func isWatched(_ item: MediaItem) -> Bool {
        if let local = localPlaybackRecord(for: item) {
            if local.explicitlyUnwatched == true { return false }
            if local.completed { return true }
        }
        return item.isPlayed
    }

    private func followingUnwatchedEpisode(after episode: MediaItem,
                                           profile: MediaServerProfile) async -> MediaItem? {
        guard let seriesID = episode.seriesID else { return nil }
        guard let episodes = try? await client(for: profile)
            .episodes(userID: profile.userID, seriesID: seriesID) else { return nil }
        return LocalEpisodeProgressionPolicy.nextEpisode(after: episode,
            in: episodes.map { $0.servedBy(profile.id) },
            isWatched: { [weak self] in self?.isWatched($0) == true })
    }

    private func advanceAfterCompletedPlayback(_ episode: MediaItem, profileID: UUID) async {
        if ProviderItem(id: episode.id) != nil {
            await advanceProviderEpisode(after: episode, profileID: profileID)
            return
        }
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let tracked = episode.seriesID == nil
            ? ((try? await details(of: episode)) ?? episode)
            : episode
        let following = await followingUnwatchedEpisode(after: tracked, profile: profile)
        guard contains(profile) else { return }
        let key = Self.seriesKey(for: tracked)
        localPlayback.removeAll { record in
            record.profileID == profileID && record.isUpNext == true
                && Self.seriesKey(for: record.item) == key
        }
        if let following { queueAsUpNext(following, explicitlyUnwatched: false) }
        persistLocalPlayback()
    }

    /// Repair records written before automatic playback completion advanced a
    /// series. It runs once per server, off the visible Library path.
    private func reconcileSeriesPositionsIfNeeded(for profile: MediaServerProfile) {
        guard !reconciledSeriesServers.contains(profile.id),
              seriesReconcileTasks[profile.id] == nil else { return }
        seriesReconcileTasks[profile.id] = Task { [weak self] in
            guard let self else { return }
            await self.reconcileSeriesPositions(for: profile)
            guard !Task.isCancelled, self.contains(profile) else { return }
            self.reconciledSeriesServers.insert(profile.id)
            self.seriesReconcileTasks[profile.id] = nil
        }
    }

    private func reconcileSeriesPositions(for profile: MediaServerProfile) async {
        let series = catalogs.flatMap(\.items).filter { $0.isSeries && $0.serverID == profile.id }
        let records: [(seriesID: String, record: LocalMediaPlayback)] = localPlayback.compactMap { record in
            guard record.profileID == profile.id, record.item.type == "Episode" else { return nil }
            if let seriesID = record.item.seriesID { return (seriesID, record) }
            guard let name = record.item.seriesName,
                  let matched = series.first(where: {
                      $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                  }) else { return nil }
            return (matched.id, record)
        }
        let grouped = Dictionary(grouping: records) { $0.seriesID }
        guard let source = try? client(for: profile) else { return }
        for (seriesID, entries) in grouped {
            let values = entries.map { $0.record }
            guard !Task.isCancelled, contains(profile) else { return }
            let hasCurrentPosition = values.contains { record in
                record.isUpNext == true || (!record.completed && record.position >= 5
                    && record.explicitlyUnwatched != true)
            }
            guard !hasCurrentPosition,
                  let anchor = values.filter(\.completed)
                    .max(by: { $0.updatedAt < $1.updatedAt })?.item else { continue }

            let serverNext = (try? await source.nextUp(
                userID: profile.userID, seriesID: seriesID))?.first?.servedBy(profile.id)
            let following: MediaItem?
            if let serverNext, !isWatched(serverNext) {
                following = serverNext
            } else if let episodes = try? await source.episodes(
                userID: profile.userID, seriesID: seriesID) {
                following = LocalEpisodeProgressionPolicy.nextEpisode(after: anchor,
                    in: episodes.map { $0.servedBy(profile.id) },
                    isWatched: { [weak self] in self?.isWatched($0) == true })
            } else {
                following = nil
            }
            guard contains(profile) else { return }
            if let following { rememberNextUp(following) }
        }
    }

    private func queueAsUpNext(_ episode: MediaItem, explicitlyUnwatched: Bool) {
        guard let profileID = serverID(of: episode) else { return }
        if let index = localPlayback.firstIndex(where: {
            $0.profileID == profileID && $0.item.id == episode.id
        }), localPlayback[index].position >= 5, !localPlayback[index].completed,
           localPlayback[index].explicitlyUnwatched != true {
            localPlayback[index].updatedAt = Date()
            return
        }
        localPlayback.removeAll { $0.profileID == profileID && $0.item.id == episode.id }
        let duration = episode.runTimeTicks.map { max(1, Double($0) / 10_000_000) } ?? 1
        localPlayback.append(LocalMediaPlayback(profileID: profileID, item: episode.servedBy(profileID),
            position: 0, duration: duration, updatedAt: Date(), completed: false,
            explicitlyUnwatched: explicitlyUnwatched, isUpNext: true))
    }

    nonisolated private static func seriesKey(for episode: MediaItem) -> String {
        if let seriesID = episode.seriesID, !seriesID.isEmpty { return "id:" + seriesID }
        if let name = episode.seriesName, !name.isEmpty {
            return "name:" + name.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return "episode:" + episode.id
    }

    /// Where a local record can belong: every connected server, and the IPTV
    /// provider, whose titles are played and remembered the same way.
    private var recordSources: Set<UUID> {
        var sources = Set(profiles.map(\.id))
        if let provider = providerVOD.profile?.id { sources.insert(provider) }
        return sources
    }

    private var playbackForConnectedServers: [LocalMediaPlayback] {
        let connected = recordSources
        return localPlayback.filter { connected.contains($0.profileID) }
    }

    /// A record saved before items carried their server gets it from the
    /// record, which has always said which server it belongs to.
    nonisolated private static func marked(_ record: LocalMediaPlayback) -> LocalMediaPlayback {
        guard record.item.serverID == nil else { return record }
        var marked = record
        marked.item = record.item.servedBy(record.profileID)
        return marked
    }

    nonisolated private static func marked(_ favorite: LocalMediaFavorite) -> LocalMediaFavorite {
        guard favorite.item.serverID == nil else { return favorite }
        var marked = favorite
        marked.item = favorite.item.servedBy(favorite.profileID)
        return marked
    }

    private func persistLocalPlayback() {
        if localPlayback.isEmpty {
            defaults.removeObject(forKey: localPlaybackKey)
        } else if let data = try? JSONEncoder().encode(localPlayback) {
            defaults.set(data, forKey: localPlaybackKey)
        }
    }

    private func persistLocalFavorites() {
        if localFavorites.isEmpty {
            defaults.removeObject(forKey: localFavoritesKey)
        } else if let data = try? JSONEncoder().encode(localFavorites) {
            defaults.set(data, forKey: localFavoritesKey)
        }
    }

    // MARK: - Snapshots

    /// Save only the last complete answer. A half-loaded refresh never
    /// replaces the screen that is known to work.
    private func persistLibrarySnapshot(for profile: MediaServerProfile) {
        guard contains(profile), let state = servers[profile.id] else { return }
        let snapshot = LibrarySnapshot(roots: state.roots, collections: state.collections,
            importedCatalogs: state.importedCatalogs, catalogs: state.catalogs,
            counts: state.counts, refreshedAt: state.refreshedAt ?? Date())
        let url = Self.snapshotURL(profileID: profile.id)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Disk decoding is dramatically cheaper than repeating several server
    /// requests, and it happens once per server at launch.
    private func restoreLibrarySnapshot(for profile: MediaServerProfile, adoptingLists: Bool) {
        var state = servers[profile.id] ?? MediaServerState()
        defer { servers[profile.id] = state }
        let url = Self.snapshotURL(profileID: profile.id)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else { return }
        // Written before items carried their server, a snapshot's items are
        // given it here.
        let mark = { (items: [MediaItem]) in
            items.map { $0.serverID == nil ? $0.servedBy(profile.id) : $0 }
        }
        state.roots = mark(snapshot.roots)
        state.collections = mark(snapshot.collections)
        state.importedCatalogs = mark(snapshot.importedCatalogs)
        state.catalogs = snapshot.catalogs.filter { !Self.isMDBListShelfID($0.root.id) }.map { shelf in
            MediaCatalog(root: shelf.root.serverID == nil ? shelf.root.servedBy(profile.id) : shelf.root,
                         items: mark(shelf.items))
        }
        state.counts = snapshot.counts
        state.refreshedAt = snapshot.refreshedAt
        state.loadFailed = false
        // MDBList shelves used to be saved with the server that was active,
        // when a list was matched against one server's titles. They are the
        // Library's own now and kept apart, in their own snapshot.
        if adoptingLists {
            let lists = snapshot.catalogs.filter { Self.isMDBListShelfID($0.root.id) }
            if !lists.isEmpty {
                mdbListShelves = lists.map { MediaCatalog(root: $0.root, items: mark($0.items)) }
                persistMDBListSnapshot()
            }
        }
    }

    nonisolated private static func snapshotURL(profileID: UUID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lineup-media-library-\(profileID.uuidString).json")
    }

    nonisolated private static var mdbListSnapshotURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lineup-media-library-mdblist.json")
    }

    private func persistMDBListSnapshot() {
        let shelves = mdbListShelves
        let url = Self.mdbListSnapshotURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(shelves) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func restoreMDBListSnapshot() -> Bool {
        guard let data = try? Data(contentsOf: Self.mdbListSnapshotURL),
              let shelves = try? JSONDecoder().decode([MediaCatalog].self, from: data) else { return false }
        mdbListShelves = shelves
        return true
    }

    // MARK: - Search

    /// What one server found for a search.
    struct SearchGroup: Identifiable {
        let serverID: UUID
        let serverName: String
        let items: [MediaItem]
        var id: UUID { serverID }
    }

    /// Search every connected server at once, each server's results kept
    /// together, servers in the order they were added.
    ///
    /// Kept apart rather than merged into one list: merged, a title both
    /// servers hold showed only the first server's copy, and the second
    /// server's results queued behind every one of the first's, which read as
    /// the second server not being searched at all. A loaded shelf stays
    /// searchable too, so a server that fails still answers from what is on
    /// screen. Only an empty result raises the error.
    func search(_ query: String) async throws -> [SearchGroup] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let shelved = shelves.flatMap(\.items).filter {
            $0.hasDetailPage && $0.name.localizedStandardContains(term)
        }
        let targets = profiles.map { ($0, try? client(for: $0)) }
        let answers = await withTaskGroup(of: (Int, Result<[MediaItem], Error>).self) { group in
            for (index, (profile, source)) in targets.enumerated() {
                group.addTask {
                    guard let source else { return (index, .failure(JellyfinError.authenticationFailed)) }
                    do {
                        let found = try await source.search(userID: profile.userID, query: term)
                        return (index, .success(found.map { $0.servedBy(profile.id) }))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var answers: [Int: Result<[MediaItem], Error>] = [:]
            for await (index, answer) in group { answers[index] = answer }
            return answers
        }
        var groups: [SearchGroup] = []
        var serverError: Error?
        for (index, (profile, _)) in targets.enumerated() {
            var found: [MediaItem] = []
            switch answers[index] {
            case .success(let items)?: found = items
            case .failure(let error)?: if serverError == nil { serverError = error }
            case nil: break
            }
            // Within a server a title is listed once, whichever of its search
            // and its shelves found it.
            var seen: Set<String> = []
            let items = (found + shelved.filter { $0.serverID == profile.id }).filter { item in
                let keys = [item.libraryKey] + MediaTitleMatch.keys(of: item)
                guard !keys.contains(where: seen.contains) else { return false }
                seen.formUnion(keys)
                return true
            }
            if !items.isEmpty {
                groups.append(SearchGroup(serverID: profile.id, serverName: profile.name, items: items))
            }
        }
        // The IPTV provider's films and shows, after every server's.
        if let provider = await providerSearchGroup(term) { groups.append(provider) }
        if groups.isEmpty, let serverError { throw serverError }
        return groups
    }

    // MARK: - Shelves

    /// Add a shelf for a library or collection, on the server it belongs to.
    ///
    /// A shelf whose contents will not load is still added, empty. It was
    /// asked for by name, and a row with a title and nothing under it can be
    /// seen, understood and removed; a choice that quietly does nothing cannot.
    func addShelf(_ root: MediaItem) async {
        if ProviderItem(id: root.id) != nil { await addProviderShelf(root); return }
        guard let profile = profile(for: root) else { return }
        let shelfRoot = root.servedBy(profile.id)
        let shelfID = MediaCatalog.id(for: shelfRoot)
        guard !catalogs.contains(where: { $0.id == shelfID }) else { return }
        var loaded: [MediaItem] = []
        do {
            loaded = try await client(for: profile).items(userID: profile.userID, parentID: root.id)
                .map { $0.servedBy(profile.id) }
        } catch {
            if !Self.isCancellation(error) { report(error, from: profile) }
        }
        guard !catalogs.contains(where: { $0.id == shelfID }) else { return }
        update(profile) { $0.catalogs.append(MediaCatalog(root: shelfRoot, items: loaded)) }
        saveShelfIDs(for: profile)
        persistLibrarySnapshot(for: profile)
    }

    func removeShelf(_ catalog: MediaCatalog) {
        if ProviderItem(id: catalog.root.id) != nil, let provider = catalog.root.serverID {
            providerShelves.removeAll { $0.id == catalog.id }
            saveProviderShelfIDs(savedProviderShelfIDs(for: provider).filter { $0 != catalog.root.id },
                                 for: provider)
        } else if Self.isMDBListShelfID(catalog.id) {
            mdbListShelves.removeAll { $0.id == catalog.id }
            saveMDBListShelfIDs(savedMDBListShelfIDs().filter { "mdblist:\($0)" != catalog.id })
            persistMDBListSnapshot()
        } else if let profile = profile(for: catalog.root) {
            update(profile) { state in state.catalogs.removeAll { $0.id == catalog.id } }
            saveShelfIDs(for: profile)
            persistLibrarySnapshot(for: profile)
        }
        if selectedHeroCatalogID == catalog.id {
            selectedHeroCatalogID = nil
            saveHeroCatalogID(nil)
        }
    }

    var availableShelves: [MediaItem] { availableLibraries + availableCatalogs }

    /// The servers' own libraries that are not already a shelf.
    var availableLibraries: [MediaItem] { profiles.flatMap { availableLibraries(on: $0) } }

    /// The imported catalogs, and any hand-made collection, that are not
    /// already a shelf. On a Nullfin server this is the list the viewer came for.
    var availableCatalogs: [MediaItem] { profiles.flatMap { availableCatalogs(on: $0) } }

    func availableLibraries(on profile: MediaServerProfile) -> [MediaItem] {
        unshelved(state(of: profile).roots)
    }

    func availableCatalogs(on profile: MediaServerProfile) -> [MediaItem] {
        let held = state(of: profile)
        var seen: Set<String> = []
        return unshelved(held.importedCatalogs + held.collections)
            .filter { seen.insert($0.libraryKey).inserted }
    }

    private func unshelved(_ items: [MediaItem]) -> [MediaItem] {
        let shelved = Set(catalogs.map(\.id))
        return items.filter { !shelved.contains(MediaCatalog.id(for: $0)) }
    }

    // MARK: - Addon catalogs

    /// What each addon offers that its server is not importing yet, on every
    /// server.
    ///
    /// A catalog arrives switched off, and the server only imports the ones
    /// switched on -- so adding an addon puts nothing in the library by
    /// itself, which is why a newly added addon appeared to do nothing here.
    /// Already-enabled catalogs are left out: those are collections, and the
    /// shelf list above already offers them.
    func loadAddonCatalogs() async {
        await loadAddonCatalogs(on: profiles)
    }

    private func loadAddonCatalogs(on targets: [MediaServerProfile]) async {
        await withTaskGroup(of: Void.self) { group in
            for profile in targets {
                group.addTask { await self.loadAddonCatalogs(of: profile) }
            }
        }
    }

    private func loadAddonCatalogs(of profile: MediaServerProfile) async {
        guard let source = try? client(for: profile) else { return }
        do {
            let addons = try await source.addons().filter(\.enabled)
            var groups: [AddonCatalogGroup] = []
            var imported: [MediaItem] = []
            for addon in addons {
                let offered = (try? await source.addonCatalogs(addonID: addon.id)) ?? []
                let available = offered.filter { !$0.enabled }
                if !available.isEmpty {
                    groups.append(AddonCatalogGroup(serverID: profile.id, addonID: addon.id,
                                                    name: addon.name, catalogs: available))
                }
                // A catalog already switched on has a collection waiting, and
                // the addon has just named it. Ask for that one item rather
                // than hoping it turns up in a list of everything.
                for enabled in offered where enabled.enabled {
                    guard let id = enabled.collectionId else { continue }
                    guard let item = try? await source.item(userID: profile.userID, itemID: id) else { continue }
                    imported.append(item.servedBy(profile.id))
                }
            }
            update(profile) { state in
                state.addonGroups = groups
                state.importedCatalogs = imported
                state.addonsUnavailable = false
            }
        } catch {
            // Anything but a refusal is worth reporting; a refusal is the
            // ordinary answer from a plain Jellyfin server or a member account.
            let refused = isRefusal(error)
            update(profile) { state in
                state.addonGroups = []
                state.importedCatalogs = []
                state.addonsUnavailable = refused
            }
            if !refused, !Self.isCancellation(error) { report(error, from: profile) }
        }
    }

    /// Which catalog, on which server, an import is for.
    private func importKey(_ catalog: NullfinCatalog, in group: AddonCatalogGroup) -> String {
        group.serverID.uuidString + "|" + catalog.catalogId
    }

    func isImporting(_ catalog: NullfinCatalog, in group: AddonCatalogGroup) -> Bool {
        importing.contains(importKey(catalog, in: group))
    }

    /// Switch a catalog on and put it on screen as a shelf.
    ///
    /// Three steps, because the server needs all three: record the choice, ask
    /// it to import, then wait for the collection to exist. Nothing is
    /// browsable in between, and the import is the server walking a catalog,
    /// so this is minutes rather than seconds.
    ///
    /// The catalog stays in the list it was chosen from for as long as this
    /// runs. It used to be taken out the moment the server accepted the
    /// switch, on the reasoning that it was enabled now whatever happened
    /// next -- but what happened next could be a wait nobody sat through, and
    /// then the catalog was gone from the list without ever becoming a shelf.
    /// Vanishing is the worst of the answers. It leaves when it becomes a
    /// shelf, and not before.
    ///
    /// The waiting is owned here rather than by the screen that started it, so
    /// it survives the screen closing -- and so a second press can call it off.
    func enableCatalog(_ catalog: NullfinCatalog, in group: AddonCatalogGroup) {
        let key = importKey(catalog, in: group)
        guard let profile = profiles.first(where: { $0.id == group.serverID }),
              importTasks[key] == nil else { return }
        importing.insert(key)
        importTasks[key] = Task { @MainActor [weak self] in
            await self?.runImport(of: catalog, addonID: group.addonID, on: profile)
            self?.importTasks[key] = nil
            self?.importing.remove(key)
        }
    }

    /// Stop waiting on an import. The server keeps going: this only gives up
    /// watching for it, which is the difference between a screen that can be
    /// left and one that holds someone there.
    func stopWaiting(for catalog: NullfinCatalog, in group: AddonCatalogGroup) {
        importTasks[importKey(catalog, in: group)]?.cancel()
    }

    private func runImport(of catalog: NullfinCatalog, addonID: String,
                           on profile: MediaServerProfile) async {
        guard let source = try? client(for: profile) else { return }
        do {
            try await source.setCatalog(addonID: addonID, catalogID: catalog.catalogId, enabled: true)
        } catch {
            report(error, from: profile)
            return
        }
        // Read the switch back before waiting ten minutes on it. A server that
        // accepted the request but did not record the choice is a different
        // problem from a slow import, and it is worth a second to tell them
        // apart rather than showing the same spinner for both.
        let confirmed = (try? await source.addonCatalogs(addonID: addonID))?
            .first { $0.catalogId == catalog.catalogId }
        if let confirmed, !confirmed.enabled {
            errorMessage = catalog.name + " could not be switched on: the server accepted the request but still reports the catalog as off. Check that this account is allowed to change catalogs on the server."
            return
        }
        do { try await source.refreshLibrary() } catch {
            report(error, from: profile)
            return
        }
        await waitForImport(of: catalog, addonID: addonID, on: profile)
    }

    private func drop(_ catalog: NullfinCatalog, from profile: MediaServerProfile) {
        update(profile) { state in
            state.addonGroups = state.addonGroups.compactMap { group in
                let rest = group.catalogs.filter { $0.catalogId != catalog.catalogId }
                return rest.isEmpty ? nil : AddonCatalogGroup(serverID: group.serverID,
                    addonID: group.addonID, name: group.name, catalogs: rest)
            }
        }
    }

    /// Poll until the catalog's collection turns up, then shelve it.
    ///
    /// The server gives no signal when one catalog is done, so the collection
    /// appearing is the signal. It gives up after a few minutes rather than
    /// waiting forever; the shelf can still be added by hand once the import
    /// finishes.
    private func waitForImport(of catalog: NullfinCatalog, addonID: String,
                               on profile: MediaServerProfile) async {
        guard let source = try? client(for: profile) else { return }
        // A full library refresh re-imports every enabled catalog, not just
        // this one, so on a server with several addons it is minutes of work.
        // Ten of them. The first look happens before any waiting, because a
        // catalog the server already holds should not cost ten seconds.
        for attempt in 0..<61 {
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
            guard contains(profile) else { return }
            guard let found = await importedCollection(for: catalog, addonID: addonID,
                                                       source: source, profile: profile)
            else { continue }
            await addShelf(found)
            drop(catalog, from: profile)
            await reload(servers: [profile])
            return
        }
        guard !Task.isCancelled else { return }
        // Say what was actually observed. "Still importing" read the same
        // whether the server was working on it or had never started, and those
        // want different things done about them.
        let latest = (try? await source.addonCatalogs(addonID: addonID))?
            .first { $0.catalogId == catalog.catalogId }
        let collectionCount = ((try? await source.allCollections(userID: profile.userID)) ?? []).count
        let state = latest?.enabled == true ? "switched on" : "switched off"
        let named = latest?.collectionId.map { "names collection " + $0 + " for it" }
            ?? "has not named a collection for it"
        errorMessage = catalog.name + " did not finish importing in ten minutes. The server reports it as "
            + state + " and " + named + ", with " + String(collectionCount)
            + " collections visible to this account. If it is not in the server's own library either, the server has not imported it and nothing here can add it yet."
        await reload(servers: [profile])
    }

    /// The collection a catalog became, asked for three ways.
    ///
    /// The id the catalog carried when it was chosen is the obvious one and
    /// the one this used to rely on alone -- but a catalog the server has
    /// never imported carries no id at all until the server resolves one, and
    /// it only resolves one once the import has run. So for exactly the case
    /// that matters, a freshly switched-on catalog, that id is nil or stale,
    /// and watching it alone is watching for something that will never arrive.
    /// Hence asking the server what the id is *now*, on every pass, and
    /// falling back to the collection that carries the catalog's name for a
    /// server that imports it without ever naming it back.
    private func importedCollection(for catalog: NullfinCatalog, addonID: String,
                                    source: JellyfinClient,
                                    profile: MediaServerProfile) async -> MediaItem? {
        if let id = catalog.collectionId,
           let item = try? await source.item(userID: profile.userID, itemID: id) {
            return item.servedBy(profile.id)
        }
        let current = (try? await source.addonCatalogs(addonID: addonID))?
            .first { $0.catalogId == catalog.catalogId }
        if let id = current?.collectionId, id != catalog.collectionId,
           let item = try? await source.item(userID: profile.userID, itemID: id) {
            return item.servedBy(profile.id)
        }
        return (try? await source.allCollections(userID: profile.userID))?
            .first { $0.name.caseInsensitiveCompare(catalog.name) == .orderedSame }?
            .servedBy(profile.id)
    }

    /// Whether a request was called off rather than refused. URLSession reports
    /// this as an error whose whole description is "cancelled", which is exactly
    /// what a viewer should never be shown.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError { return url.code == .cancelled }
        return (error as NSError).code == NSURLErrorCancelled
    }

    /// A server that will not answer, as opposed to one that answered badly.
    /// A plain Jellyfin server does not have these routes and a member account
    /// is not allowed them; neither is worth putting in front of the viewer as
    /// an error.
    private func isRefusal(_ error: Error) -> Bool {
        guard let error = error as? JellyfinError else { return false }
        switch error {
        case .authenticationFailed: return true
        case .server(let status): return status == 403 || status == 404
        default: return false
        }
    }

    /// A failure, named for its server when there is more than one it could
    /// have come from.
    private func report(_ error: Error, from profile: MediaServerProfile) {
        errorMessage = profiles.count > 1
            ? profile.name + ": " + error.localizedDescription
            : error.localizedDescription
    }

    // MARK: - Artwork

    func imageURL(for item: MediaItem, width: Int = 600) -> URL? {
        // A source that names its artwork outright is asked for that address
        // directly, and the server is never reached at all.
        if let poster = item.posterURL { return URL(string: poster) }
        guard let profile = profile(for: item) else { return nil }
        return try? client(for: profile).imageURL(itemID: item.id, maxWidth: width)
    }

    /// Episode primary art is normally a 16:9 still. A mixed Continue Watching
    /// row uses portrait cards to stay aligned with movies, so use the parent
    /// show's poster there instead of stretching and cropping the still.
    func seriesPosterURL(for episode: MediaItem, width: Int = 600) -> URL? {
        // A provider's episode gets its show's cover, from the list in hand.
        if case .episode(let seriesID, _)? = ProviderItem(id: episode.id) {
            guard let ready = providerVOD.ready,
                  let cover = ready.index.show(seriesID: seriesID, in: ready.catalog)?.cover else { return nil }
            return URL(string: cover)
        }
        guard episode.type == "Episode", let seriesID = episode.seriesID,
              let profile = profile(for: episode) else { return nil }
        return try? client(for: profile).imageURL(itemID: seriesID, maxWidth: width)
    }

    // Asking for art the server did not report leaves a request to 404 behind
    // every hero, so each of these answers nil unless the item claims one.
    func backdropURL(for item: MediaItem, width: Int = 1280) -> URL? {
        if let backdrop = item.backdropURL { return URL(string: backdrop) }
        guard item.hasBackdrop, let profile = profile(for: item) else { return nil }
        return try? client(for: profile).imageURL(itemID: item.id, type: "backdrop", maxWidth: width)
    }

    func logoURL(for item: MediaItem, width: Int = 800) -> URL? {
        if let logo = item.logoArtworkURL { return URL(string: logo) }
        guard item.hasLogo, let profile = profile(for: item) else { return nil }
        return try? client(for: profile).imageURL(itemID: item.id, type: "logo", maxWidth: width)
    }

    // MARK: - Playback

    func playbackURL(for item: MediaItem) -> URL? {
        guard let profile = profile(for: item) else { return nil }
        return try? client(for: profile).playbackURL(itemID: item.id)
    }

    /// The servers to ask for a title's streams: its own first, then every
    /// other connected server, each about its own copy of the title.
    ///
    /// Only a film or an episode goes looking elsewhere. Those are what another
    /// server can be asked about by name; anything else is its own server's.
    func streamServers(for item: MediaItem) -> [MediaServerProfile] {
        // A provider's title has no server of its own; each is asked about its
        // own copy, the way it is for another server's title.
        if ProviderItem(id: item.id) != nil {
            return item.type == "Movie" || item.type == "Episode" ? profiles : []
        }
        guard let home = profile(for: item) else { return [] }
        guard item.type == "Movie" || item.type == "Episode" else { return [home] }
        return [home] + profiles.filter { $0.id != home.id }
    }

    /// Why another server added nothing to a title's streams.
    enum StreamLookupError: LocalizedError {
        /// It holds no copy of the title. Carries how the copy was looked
        /// for, so the line that says so can say what was tried.
        case notOnServer(tried: String)

        var errorDescription: String? { "Doesn't have this title" }

        var tried: String {
            switch self {
            case .notOnServer(let tried): tried
            }
        }
    }

    /// One server's streams for a title, each marked with the server and the
    /// item it plays from. The title's own server is asked about the item
    /// itself; another server about its own copy, and it throws
    /// `StreamLookupError.notOnServer` when it holds none.
    func playbackSources(for item: MediaItem, on profile: MediaServerProfile) async throws -> [MediaPlaybackSource] {
        let target: MediaItem
        if serverID(of: item) == profile.id {
            target = item
        } else {
            var lookup = CounterpartLookup()
            guard let copy = try await counterpart(of: item, on: profile, lookup: &lookup) else {
                throw StreamLookupError.notOnServer(tried: lookup.summary)
            }
            target = copy
        }
        return try await client(for: profile).playbackInfo(itemID: target.id).mediaSources
            .filter { $0.path != "/videos/no-streams" && $0.name != "No streams found" }
            .map { source in
                var source = source
                source.serverID = profile.id
                source.serverName = profile.name
                source.itemID = target.id
                return source
            }
    }

    /// Where a stream plays from: the server that offered it, as its copy of
    /// the title, or the provider's own address for one of its films.
    func playbackURL(for item: MediaItem, source: MediaPlaybackSource) -> URL? {
        if let direct = source.directURL { return direct }
        let offering = source.serverID.flatMap { id in profiles.first { $0.id == id } }
        guard let profile = offering ?? profile(for: item) else { return nil }
        return try? client(for: profile).playbackURL(itemID: source.itemID ?? item.id,
                                                     mediaSourceID: source.sourceID)
    }

    /// Which kind of server a profile is, asked of the server once a session.
    /// A server that does not answer is taken for plain Jellyfin this time
    /// and asked again next time.
    func serverKind(of profile: MediaServerProfile) async -> MediaServerKind {
        if let known = serverKinds[profile.id] { return known }
        guard let info = try? await client(for: profile).publicInfo() else { return .jellyfin }
        serverKinds[profile.id] = info.kind
        return info.kind
    }

    /// How a title was looked for on another server, for the line that says
    /// it was not found there: the ids asked about, the names searched for,
    /// what came back, and the nearest of it.
    struct CounterpartLookup: Sendable {
        var askedIDs: [String] = []
        var idFailure: String?
        var searchedNames: [String] = []
        var results = 0
        var nearest: String?
        /// Set when the show was found and the episode was not in it.
        var missingEpisode: String?

        var summary: String {
            var parts: [String] = []
            if !askedIDs.isEmpty {
                parts.append("Asked for " + askedIDs.joined(separator: ", ")
                             + (idFailure.map { " (\($0))" } ?? ""))
            }
            if !searchedNames.isEmpty {
                let names = searchedNames.map { "“\($0)”" }.joined(separator: ", ")
                let found = results == 0 ? "no results"
                    : (results == 1 ? "1 result" : "\(results) results")
                        + (nearest.map { ", nearest \($0)" } ?? "")
                parts.append((parts.isEmpty ? "Searched " : "searched ") + names + ": " + found)
            }
            if let missingEpisode { parts.append(missingEpisode) }
            return parts.isEmpty ? "Nothing to look it up by" : parts.joined(separator: " · ")
        }
    }

    /// The same title on another server, or nil when that server has none.
    ///
    /// Asked by id first wherever the server can be: AIOStreams for the item
    /// the title's ids pack into, Remux for the item holding them. That is
    /// exact, and needs no search to have found the title. Then by name, the
    /// way any server can be asked, keeping the result that is the same title
    /// by its IMDb, TMDB or TVDB id, or by its name and year. An episode is
    /// the same season and number in the same show.
    func counterpart(of item: MediaItem, on profile: MediaServerProfile,
                     lookup: inout CounterpartLookup) async throws -> MediaItem? {
        let key = (serverID(of: item)?.uuidString ?? "") + "|" + item.id + ">" + profile.id.uuidString
        if let cached = counterparts[key], Date().timeIntervalSince(cached.storedAt) < 600,
           let copy = cached.item {
            return copy
        }
        let found: MediaItem?
        if item.type == "Episode" {
            found = try await counterpartEpisode(of: item, on: profile, lookup: &lookup)
        } else {
            found = try await counterpartTitle(of: item, on: profile, lookup: &lookup)
        }
        // Only a copy found is remembered. A miss is asked again next time:
        // a server that builds items on demand may simply not have finished.
        if let found { counterparts[key] = CachedCounterpart(item: found, storedAt: Date()) }
        return found
    }

    /// A film or a show on another server.
    private func counterpartTitle(of title: MediaItem, on profile: MediaServerProfile,
                                  lookup: inout CounterpartLookup) async throws -> MediaItem? {
        let source = try client(for: profile)
        let kind = await serverKind(of: profile)
        if let found = await counterpartByID(of: title, on: profile, kind: kind, lookup: &lookup) {
            return found
        }
        for term in MediaTitleMatch.searchTerms(for: title.name) {
            lookup.searchedNames.append(term)
            let found = try await source.search(userID: profile.userID, query: term, types: [title.type])
            lookup.results += found.count
            if let match = found.first(where: { MediaTitleMatch.isSame(title, $0) }) {
                return await opened(match, on: profile, kind: kind)
            }
            if lookup.nearest == nil, let first = found.first { lookup.nearest = Self.described(first) }
        }
        return nil
    }

    /// A title asked for by its IMDb, TMDB and TVDB ids, on a server that can
    /// be asked that way. A failure here is no answer rather than an error:
    /// the search by name is still to come.
    private func counterpartByID(of title: MediaItem, on profile: MediaServerProfile,
                                 kind: MediaServerKind, lookup: inout CounterpartLookup) async -> MediaItem? {
        let ids = MediaTitleMatch.providerIDs(of: title)
        guard !ids.isEmpty, kind != .jellyfin, let source = try? client(for: profile) else { return nil }
        let found: [MediaItem]
        do {
            switch kind {
            case .aiostreams:
                let packed = Self.aiostreamsIDs(of: ids, as: title.type == "Series" ? .series : .movie)
                guard !packed.isEmpty else { return nil }
                lookup.askedIDs += packed.map { $0.label }
                found = try await source.items(userID: profile.userID, ids: packed.map { $0.id })
            case .remux:
                lookup.askedIDs += Self.providerOrder.compactMap { provider in
                    ids[provider].map { Self.providerLabel(provider) + " " + $0 }
                }
                found = try await source.items(userID: profile.userID, providerIDs: ids, types: [title.type])
            case .jellyfin:
                return nil
            }
        } catch {
            if !Self.isCancellation(error) { lookup.idFailure = error.localizedDescription }
            return nil
        }
        // A server that ignored the filter answered with whatever came first,
        // so only what is the same title by its ids counts.
        guard let match = found.first(where: { candidate in
            let shared = MediaTitleMatch.providerIDs(of: candidate)
            return ids.contains { shared[$0.key] == $0.value } && MediaTitleMatch.isSame(title, candidate)
        }) else { return nil }
        return match.servedBy(profile.id)
    }

    /// A match opened on its server before it is used, where opening means
    /// something. Gelato answers a search with results that only become
    /// library items -- with an id its other routes accept -- once an item
    /// route is called with them, and the opened item's id is the one to use
    /// from then on. AIOStreams' ids are the titles themselves, with nothing
    /// to open, and its item route goes looking for streams.
    private func opened(_ match: MediaItem, on profile: MediaServerProfile,
                        kind: MediaServerKind) async -> MediaItem {
        guard kind != .aiostreams, let source = try? client(for: profile) else {
            return match.servedBy(profile.id)
        }
        let opened = (try? await source.item(userID: profile.userID, itemID: match.id)) ?? match
        return opened.servedBy(profile.id)
    }

    private func counterpartEpisode(of episode: MediaItem, on profile: MediaServerProfile,
                                    lookup: inout CounterpartLookup) async throws -> MediaItem? {
        guard let season = episode.parentIndexNumber, let number = episode.indexNumber,
              let showName = episode.seriesName, !showName.isEmpty else {
            lookup.missingEpisode = "Its own server gives it no season and number"
            return nil
        }
        // The show as its own server describes it: its ids are what find it on
        // another server. A server that will not say still leaves its name.
        var show = MediaItem(id: episode.seriesID ?? "", name: showName, type: "Series",
                             overview: nil, productionYear: nil, primaryImageAspectRatio: nil,
                             childCount: nil, serverID: episode.serverID)
        if episode.seriesID != nil, let described = try? await details(of: show) { show = described }
        let source = try client(for: profile)
        let place = episode.episodeCode ?? "S\(season)E\(number)"
        // AIOStreams packs an episode's id from its show's, so the episode is
        // asked for directly.
        if await serverKind(of: profile) == .aiostreams {
            let packed = Self.aiostreamsIDs(of: MediaTitleMatch.providerIDs(of: show), as: .episode,
                                            season: season, episode: number)
            if !packed.isEmpty {
                lookup.askedIDs += packed.map { $0.label + " " + place }
                do {
                    let found = try await source.items(userID: profile.userID, ids: packed.map { $0.id })
                    if let match = found.first(where: {
                        $0.type == "Episode" && $0.parentIndexNumber == season && $0.indexNumber == number
                    }) {
                        return match.servedBy(profile.id)
                    }
                } catch {
                    if !Self.isCancellation(error) { lookup.idFailure = error.localizedDescription }
                }
            }
        }
        guard let match = try await counterpartTitle(of: show, on: profile, lookup: &lookup) else { return nil }
        // A show a server has only just built from a search can be missing
        // its episodes for a moment while the server fetches them, so an
        // empty answer is asked again before it is believed.
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
            let episodes = try await source.episodes(userID: profile.userID, seriesID: match.id)
            if let found = episodes.first(where: { $0.parentIndexNumber == season && $0.indexNumber == number }) {
                return found.servedBy(profile.id)
            }
            if !episodes.isEmpty { break }
        }
        lookup.missingEpisode = "Has the show, not \(place)"
        return nil
    }

    // MARK: - The IPTV provider's films and shows

    /// The IPTV provider, as one more place to look for a film's or an
    /// episode's streams, when one is signed in.
    func streamProvider(for item: MediaItem) -> (id: UUID, name: String)? {
        guard item.type == "Movie" || item.type == "Episode",
              let profile = providerVOD.provider?.profile else { return nil }
        return (profile.id, profile.name)
    }

    /// The provider's streams for a title: each of its films that is this
    /// film, or this episode in each of its shows that is this show, played
    /// from the provider directly.
    func providerSources(for item: MediaItem) async throws -> [MediaPlaybackSource] {
        guard let provider = providerVOD.provider else {
            throw StreamLookupError.notOnServer(tried: "No IPTV provider is signed in")
        }
        let (catalog, index) = try await providerVOD.catalog()
        // A provider's own film or episode plays itself first.
        if let place = ProviderItem(id: item.id) {
            // Numbered by the provider it came from: another provider's same
            // numbers are other titles.
            guard item.serverID == provider.profile.id else {
                throw StreamLookupError.notOnServer(tried: "It came from a provider you are no longer signed in to")
            }
            return try await providerSources(for: place, item: item, catalog: catalog, index: index,
                                             provider: provider)
        }
        if item.type == "Episode" {
            guard let season = item.parentIndexNumber, let number = item.indexNumber,
                  let showName = item.seriesName, !showName.isEmpty else {
                throw StreamLookupError.notOnServer(tried: "Its own server gives it no season and number")
            }
            // The show as its own server describes it, for its TMDB id.
            var show = MediaItem(id: item.seriesID ?? "", name: showName, type: "Series",
                                 overview: nil, productionYear: nil, primaryImageAspectRatio: nil,
                                 childCount: nil, serverID: item.serverID)
            if item.seriesID != nil, let described = try? await details(of: show) { show = described }
            let shows = index.shows(for: show, in: catalog)
            guard !shows.isEmpty else {
                throw StreamLookupError.notOnServer(tried: Self.providerMiss(for: show, among: catalog.shows.count,
                                                                             kind: "shows"))
            }
            var sources: [MediaPlaybackSource] = []
            for series in shows.prefix(4) {
                guard let episodes = try? await providerVOD.episodes(of: series) else { continue }
                for episode in episodes where episode.season == season && episode.episodeNumber == number {
                    guard let url = provider.client.episodeURL(for: episode) else { continue }
                    sources.append(Self.providerSource(id: "series-\(series.seriesID)-\(episode.id)",
                        title: series.name + " · " + episode.title, container: episode.containerExtension,
                        url: url, provider: provider.profile))
                }
            }
            guard !sources.isEmpty else {
                throw StreamLookupError.notOnServer(tried: "Has the show, not "
                    + (item.episodeCode ?? "S\(season)E\(number)"))
            }
            return sources
        }
        let films = index.films(for: item, in: catalog)
        let sources = films.compactMap { film -> MediaPlaybackSource? in
            guard let url = provider.client.movieURL(for: film) else { return nil }
            return Self.providerSource(id: "movie-\(film.streamID)", title: film.name,
                                       container: film.containerExtension, url: url, provider: provider.profile)
        }
        guard !sources.isEmpty else {
            throw StreamLookupError.notOnServer(tried: Self.providerMiss(for: item, among: catalog.films.count,
                                                                         kind: "films"))
        }
        return sources
    }

    /// The streams of one of the provider's own titles: the title itself, and
    /// for a film, every other copy the provider lists of it.
    private func providerSources(for place: ProviderItem, item: MediaItem, catalog: ProviderVOD.Catalog,
                                 index: ProviderVOD.Index,
                                 provider: (profile: XtreamProfile, client: XtreamClient))
        async throws -> [MediaPlaybackSource] {
        switch place {
        case .film(let streamID):
            guard let film = index.film(streamID: streamID, in: catalog) else {
                throw StreamLookupError.notOnServer(tried: "The provider no longer lists it")
            }
            let copies = [film] + index.films(for: item, in: catalog).filter { $0.streamID != streamID }
            return copies.compactMap { copy -> MediaPlaybackSource? in
                guard let url = provider.client.movieURL(for: copy) else { return nil }
                return Self.providerSource(id: "movie-\(copy.streamID)", title: copy.name,
                                           container: copy.containerExtension, url: url, provider: provider.profile)
            }
        case .episode(let seriesID, let episodeID):
            guard let show = index.show(seriesID: seriesID, in: catalog),
                  let episode = try await providerVOD.episodes(of: show).first(where: { $0.id == episodeID }),
                  let url = provider.client.episodeURL(for: episode) else {
                throw StreamLookupError.notOnServer(tried: "The provider no longer lists it")
            }
            return [Self.providerSource(id: "series-\(seriesID)-\(episode.id)",
                                        title: show.name + " · " + episode.title,
                                        container: episode.containerExtension, url: url,
                                        provider: provider.profile)]
        default:
            return []
        }
    }

    /// A provider's film or episode as a stream in the list: its own name as
    /// the release, "IPTV" as where it comes from, the provider as its server.
    private static func providerSource(id: String, title: String, container: String?, url: URL,
                                       provider: XtreamProfile) -> MediaPlaybackSource {
        var source = MediaPlaybackSource(
            sourceID: id, name: title, path: nil, container: container, size: nil, bitrate: nil,
            remux: MediaPlaybackSource.RemuxInfo(providerInfo: MediaPlaybackSource.ProviderInfo(
                source: "IPTV", filename: title, description: nil)))
        source.serverID = provider.id
        source.serverName = provider.name
        source.directURL = url
        return source
    }

    /// What the provider's list was searched for, for the line that says it
    /// has nothing: "Searched 41,203 films for TMDB 693134 and “Dune: Part Two”".
    private static func providerMiss(for title: MediaItem, among count: Int, kind: String) -> String {
        var wanted: [String] = []
        if let tmdb = MediaTitleMatch.providerIDs(of: title)["tmdb"] { wanted.append("TMDB " + tmdb) }
        wanted.append("“\(title.name)”" + (title.productionYear.map { " (\($0))" } ?? ""))
        return "Searched \(count.formatted()) \(kind) for " + wanted.joined(separator: " and ")
    }

    // MARK: - The IPTV provider's titles in the Library

    /// What is under one of the provider's places: a category's films or
    /// shows, a show's seasons, a season's episodes.
    private func providerChildren(of place: ProviderItem, provider: UUID) async throws -> [MediaItem] {
        guard provider == providerVOD.profile?.id else { return [] }
        let (catalog, index) = try await providerVOD.catalog()
        switch place {
        case .filmCategory(let category):
            return index.films(inCategory: category, in: catalog).map { ProviderVOD.item(for: $0, provider: provider) }
        case .seriesCategory(let category):
            return index.shows(inCategory: category, in: catalog).map { ProviderVOD.item(for: $0, provider: provider) }
        case .series(let seriesID):
            guard let show = index.show(seriesID: seriesID, in: catalog) else { return [] }
            let episodes = try await providerVOD.episodes(of: show)
            return ProviderVOD.seasons(of: show, episodes: episodes, provider: provider)
        case .season(let seriesID, let number):
            guard let show = index.show(seriesID: seriesID, in: catalog) else { return [] }
            return try await providerVOD.episodes(of: show).filter { $0.season == number }
                .map { ProviderVOD.item(for: $0, of: show, provider: provider) }
        case .film, .episode:
            return []
        }
    }

    /// A provider's title in full. A film is asked about (get_vod_info) for
    /// what its list entry leaves out; a show's list entry already says it
    /// all. Kept for ten minutes, like a server's: a focused poster asks.
    private func providerDetails(of item: MediaItem) async -> MediaItem {
        guard let provider = item.serverID, provider == providerVOD.profile?.id,
              let place = ProviderItem(id: item.id) else { return item }
        let key = provider.uuidString + "|" + item.id
        if let cached = detailCache[key], Date().timeIntervalSince(cached.storedAt) < 600 { return cached.item }
        guard let loaded = try? await providerVOD.catalog() else { return item }
        let (catalog, index) = loaded
        var detailed = item
        switch place {
        case .film(let streamID):
            guard let film = index.film(streamID: streamID, in: catalog) else { return item }
            let base = ProviderVOD.item(for: film, provider: provider)
            let info = try? await providerVOD.provider?.client.vodInfo(streamID: streamID)
            let cast: [String] = info?.cast.map(ProviderVOD.list(in:)) ?? []
            var people: [MediaPerson] = cast.prefix(12).map {
                MediaPerson(personID: nil, name: $0, role: nil, type: "Actor", primaryImageTag: nil)
            }
            if let director = info?.director {
                people.append(MediaPerson(personID: nil, name: director, role: nil, type: "Director",
                                          primaryImageTag: nil))
            }
            detailed = MediaItem(id: base.id, name: base.name, type: base.type, overview: info?.plot,
                                 productionYear: base.productionYear ?? XtreamVOD.year(in: info?.releaseDate),
                                 primaryImageAspectRatio: nil, childCount: nil,
                                 genres: info?.genre.map(ProviderVOD.list(in:)),
                                 communityRating: base.communityRating,
                                 runTimeTicks: info?.durationSeconds.map { Int64($0) * 10_000_000 },
                                 people: people.isEmpty ? nil : people,
                                 providerIDs: (film.tmdbID ?? info?.tmdbID).map { ["Tmdb": $0] },
                                 posterURL: base.posterURL, backdropURL: info?.backdrop, serverID: provider)
        case .series(let seriesID):
            guard let show = index.show(seriesID: seriesID, in: catalog) else { return item }
            detailed = ProviderVOD.item(for: show, provider: provider)
        default:
            return item
        }
        detailCache[key] = CachedDetail(item: detailed, storedAt: Date())
        return detailed
    }

    /// Read the IPTV provider's film and show list back into memory once the
    /// app has opened, so the first title's streams do not wait on it. A
    /// moment after launch, so it does not compete with what is drawn first.
    func prepareProviderVOD() async {
        try? await Task.sleep(for: .seconds(3))
        providerVOD.prefetch(onlyFromDevice: true)
    }

    /// The provider's chosen categories as shelves, once its list is in hand.
    func loadProviderShelves() async {
        guard let profile = providerVOD.profile else { providerShelves = []; return }
        let chosen = savedProviderShelfIDs(for: profile.id)
        // Another provider's shelves go at once: their titles are numbered
        // as that provider's.
        providerShelves.removeAll { $0.root.serverID != profile.id }
        // Read even with nothing chosen, so what is drawn from the list -- an
        // episode's show cover -- is drawn again once it is in hand.
        guard let loaded = try? await providerVOD.catalog() else { return }
        let (catalog, index) = loaded
        providerShelves = chosen.compactMap { id in
            providerShelf(id, catalog: catalog, index: index, provider: profile.id)
        }
    }

    /// The first forty of a category, in the provider's own order. See All
    /// opens the rest.
    private func providerShelf(_ rootID: String, catalog: ProviderVOD.Catalog, index: ProviderVOD.Index,
                               provider: UUID) -> MediaCatalog? {
        switch ProviderItem(id: rootID) {
        case .filmCategory(let category)?:
            guard let group = catalog.filmCategories.first(where: { $0.categoryID == category }) else { return nil }
            let films = index.films(inCategory: category, in: catalog)
            return MediaCatalog(root: ProviderVOD.shelfRoot(for: group, films: true, count: films.count,
                                                            provider: provider),
                                items: films.prefix(40).map { ProviderVOD.item(for: $0, provider: provider) })
        case .seriesCategory(let category)?:
            guard let group = catalog.showCategories.first(where: { $0.categoryID == category }) else { return nil }
            let shows = index.shows(inCategory: category, in: catalog)
            return MediaCatalog(root: ProviderVOD.shelfRoot(for: group, films: false, count: shows.count,
                                                            provider: provider),
                                items: shows.prefix(40).map { ProviderVOD.item(for: $0, provider: provider) })
        default:
            return nil
        }
    }

    /// The provider's categories not yet on a shelf, films first, each with
    /// how many titles it holds. Empty until the provider's list is in hand.
    var availableProviderShelves: (films: [MediaItem], shows: [MediaItem]) {
        guard let profile = providerVOD.profile, let ready = providerVOD.ready else { return ([], []) }
        let (catalog, index) = ready
        let shelved = Set(providerShelves.map(\.root.id))
        let films = catalog.filmCategories.map { group in
            ProviderVOD.shelfRoot(for: group, films: true,
                                  count: index.films(inCategory: group.categoryID, in: catalog).count,
                                  provider: profile.id)
        }
        let shows = catalog.showCategories.map { group in
            ProviderVOD.shelfRoot(for: group, films: false,
                                  count: index.shows(inCategory: group.categoryID, in: catalog).count,
                                  provider: profile.id)
        }
        return (films.filter { !shelved.contains($0.id) && ($0.childCount ?? 0) > 0 },
                shows.filter { !shelved.contains($0.id) && ($0.childCount ?? 0) > 0 })
    }

    /// Read the provider's list for the shelf picker, and redraw it once read.
    func loadProviderCatalog() async {
        guard providerVOD.profile != nil, providerVOD.ready == nil else { return }
        _ = try? await providerVOD.catalog()
        objectWillChange.send()
    }

    func addProviderShelf(_ root: MediaItem) async {
        guard let provider = root.serverID, ProviderItem(id: root.id) != nil else { return }
        var chosen = savedProviderShelfIDs(for: provider)
        guard !chosen.contains(root.id) else { return }
        chosen.append(root.id)
        saveProviderShelfIDs(chosen, for: provider)
        await loadProviderShelves()
    }

    /// The provider's shelves, chosen per provider: another provider's
    /// categories are numbered differently.
    private func savedProviderShelfIDs(for provider: UUID) -> [String] {
        guard let data = defaults.data(forKey: providerShelvesKey),
              let saved = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return saved[provider.uuidString] ?? []
    }

    private func saveProviderShelfIDs(_ ids: [String], for provider: UUID) {
        var saved = (defaults.data(forKey: providerShelvesKey))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        saved[provider.uuidString] = ids.isEmpty ? nil : ids
        defaults.set(try? JSONEncoder().encode(saved), forKey: providerShelvesKey)
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    /// The provider's films and shows whose names hold a search, as one group.
    private func providerSearchGroup(_ term: String) async -> SearchGroup? {
        guard let profile = providerVOD.profile,
              let loaded = try? await providerVOD.catalog() else { return nil }
        let found = loaded.index.search(term, in: loaded.catalog)
        let items = found.films.map { ProviderVOD.item(for: $0, provider: profile.id) }
            + found.shows.map { ProviderVOD.item(for: $0, provider: profile.id) }
        return items.isEmpty ? nil : SearchGroup(serverID: profile.id, serverName: profile.name, items: items)
    }

    /// When a provider's episode is watched, the next one in its show is up
    /// next, as it is for a server's.
    private func advanceProviderEpisode(after episode: MediaItem, profileID: UUID) async {
        guard case .episode(let seriesID, let episodeID)? = ProviderItem(id: episode.id),
              profileID == providerVOD.profile?.id,
              let loaded = try? await providerVOD.catalog(),
              let show = loaded.index.show(seriesID: seriesID, in: loaded.catalog),
              let episodes = try? await providerVOD.episodes(of: show),
              let position = episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        let key = Self.seriesKey(for: episode)
        localPlayback.removeAll { record in
            record.profileID == profileID && record.isUpNext == true && Self.seriesKey(for: record.item) == key
        }
        if position + 1 < episodes.count {
            queueAsUpNext(ProviderVOD.item(for: episodes[position + 1], of: show, provider: profileID),
                          explicitlyUnwatched: false)
        }
        persistLocalPlayback()
    }

    private static let providerOrder = ["imdb", "tmdb", "tvdb"]

    private static func providerLabel(_ provider: String) -> String {
        switch provider {
        case "imdb": "IMDb"
        case "tmdb": "TMDB"
        default: "TVDB"
        }
    }

    /// The AIOStreams ids a title's provider ids pack into, IMDb's first:
    /// every stream addon answers for an IMDb id, and not every one for the
    /// others.
    private static func aiostreamsIDs(of ids: [String: String], as kind: AIOStreamsItemID.Kind,
                                      season: Int? = nil, episode: Int? = nil) -> [(id: String, label: String)] {
        providerOrder.compactMap { provider -> (id: String, label: String)? in
            guard let value = ids[provider],
                  let id = AIOStreamsItemID.make(kind, provider: provider, value: value,
                                                 season: season, episode: episode) else { return nil }
            return (id, providerLabel(provider) + " " + value)
        }
    }

    /// A result as the line about a title not found names it: "“Dune” (2021)".
    private static func described(_ item: MediaItem) -> String {
        "“\(item.name)”" + (item.productionYear.map { " (\($0))" } ?? "")
    }

    // MARK: - Plumbing

    private var deviceID: String {
        if let existing = defaults.string(forKey: deviceKey) { return existing }
        let value = UUID().uuidString
        defaults.set(value, forKey: deviceKey)
        return value
    }

    private func client(for profile: MediaServerProfile) throws -> JellyfinClient {
        if let made = clients[profile.id] { return made }
        guard let token = MediaKeychainStore.token(profileID: profile.id) else {
            throw JellyfinError.authenticationFailed
        }
        let made = try JellyfinClient(serverURL: profile.serverURL, accessToken: token, deviceID: deviceID)
        clients[profile.id] = made
        return made
    }

    /// The server an item came from. An item that carries none was made here
    /// rather than handed over by a server, or saved before items carried one,
    /// and the first server answers for it.
    private func serverID(of item: MediaItem) -> UUID? {
        item.serverID ?? profiles.first?.id
    }

    private func profile(for item: MediaItem) -> MediaServerProfile? {
        guard let id = serverID(of: item) else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Whether a server is still one of the Library's: a load can outlive
    /// the server it was for.
    private func contains(_ profile: MediaServerProfile) -> Bool {
        profiles.contains { $0.id == profile.id }
    }

    /// Change one server's state, and only while it is still connected: a
    /// load that finishes after its server was removed has nowhere to land.
    private func update(_ profile: MediaServerProfile, _ change: (inout MediaServerState) -> Void) {
        guard contains(profile) else { return }
        var state = servers[profile.id] ?? MediaServerState()
        change(&state)
        servers[profile.id] = state
    }

    /// One addon on one server, and the catalogs it offers that are not
    /// switched on yet.
    struct AddonCatalogGroup: Identifiable, Hashable, Sendable {
        let serverID: UUID
        let addonID: String
        let name: String
        let catalogs: [NullfinCatalog]
        var id: String { serverID.uuidString + "|" + addonID }
    }

    nonisolated private static func mdbListShelf(_ list: MDBListCatalog,
                                                 items: [MediaItem]) -> MediaCatalog {
        let root = MediaItem(id: list.shelfID, name: list.name, type: "Folder",
            overview: "MDBList catalog", productionYear: nil,
            primaryImageAspectRatio: nil, childCount: items.count)
        return MediaCatalog(root: root, items: items)
    }

    nonisolated static func isMDBListShelfID(_ id: String) -> Bool {
        id.hasPrefix("mdblist:")
    }

    private func savedMDBListShelves() -> [String: [Int]] {
        guard let data = defaults.data(forKey: mdbListShelvesKey),
              let value = try? JSONDecoder().decode([String: [Int]].self, from: data) else { return [:] }
        return value
    }

    private func savedMDBListShelfIDs() -> [Int] {
        savedMDBListShelves()[Self.libraryWide] ?? []
    }

    private func saveMDBListShelfIDs(_ ids: [Int]) {
        if ids.isEmpty { defaults.removeObject(forKey: mdbListShelvesKey) }
        else { defaults.set(try? JSONEncoder().encode([Self.libraryWide: ids]), forKey: mdbListShelvesKey) }
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    private func selectedShelfRoots(from roots: [MediaItem], profileID: UUID) -> [MediaItem] {
        let selections = savedShelves()
        if let saved = selections[profileID.uuidString], !saved.isEmpty {
            return saved.compactMap { id in roots.first { $0.id == id } }
        }

        let movie = roots.first { root in
            let name = root.name.lowercased()
            return name.contains("trending") && name.contains("movie")
        }
        let series = roots.first { root in
            let name = root.name.lowercased()
            return name.contains("trending") && (name.contains("series") || name.contains("show") || name.contains("tv"))
        }
        var defaults = [movie, series].compactMap { $0 }
        // A server with nothing named trending still shows its own first
        // libraries: added beside another server, it must not be invisible in
        // the Library until someone goes looking for Add Shelf.
        if defaults.isEmpty { defaults = Array(roots.prefix(2)) }
        saveShelfIDs(defaults.map(\.id), profileID: profileID)
        return defaults
    }

    private func savedShelves() -> [String: [String]] {
        guard let data = defaults.data(forKey: shelvesKey),
              let value = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return value
    }

    /// A server's shelves are saved by its own ids for them.
    private func saveShelfIDs(for profile: MediaServerProfile) {
        saveShelfIDs(state(of: profile).catalogs.map(\.root.id), profileID: profile.id)
    }

    private func saveShelfIDs(_ ids: [String], profileID: UUID) {
        var value = savedShelves()
        value[profileID.uuidString] = ids
        defaults.set(try? JSONEncoder().encode(value), forKey: shelvesKey)
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    private func savedHeroCatalogs() -> [String: String] {
        guard let data = defaults.data(forKey: heroCatalogKey),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    private func saveHeroCatalogID(_ id: String?) {
        if let id { defaults.set(try? JSONEncoder().encode([Self.libraryWide: id]), forKey: heroCatalogKey) }
        else { defaults.removeObject(forKey: heroCatalogKey) }
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    /// The server that was "active" before every server was used at once, or
    /// the first server when that one is gone.
    private func formerActiveServer() -> UUID? {
        let saved = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        return profiles.first { $0.id == saved }?.id ?? profiles.first?.id
    }

    /// The hero shelf and the MDBList shelves used to be chosen per server,
    /// and only the active server's applied. They are the whole Library's now:
    /// the active server's hero carries over, and every list any server had.
    /// Written straight back, so the answer cannot shift as servers come and go.
    private func migrateLibraryChoices() {
        let lists = savedMDBListShelves()
        if lists[Self.libraryWide] == nil, !lists.isEmpty {
            let order = [formerActiveServer()].compactMap { $0 } + profiles.map(\.id)
            var ids: [Int] = []
            for server in order {
                for id in lists[server.uuidString] ?? [] where !ids.contains(id) { ids.append(id) }
            }
            if ids.isEmpty { defaults.removeObject(forKey: mdbListShelvesKey) }
            else { defaults.set(try? JSONEncoder().encode([Self.libraryWide: ids]), forKey: mdbListShelvesKey) }
        }
        let heroes = savedHeroCatalogs()
        if heroes[Self.libraryWide] == nil, !heroes.isEmpty {
            if let server = formerActiveServer(), let old = heroes[server.uuidString] {
                let id = Self.isMDBListShelfID(old) ? old : server.uuidString + "|" + old
                defaults.set(try? JSONEncoder().encode([Self.libraryWide: id]), forKey: heroCatalogKey)
            } else {
                defaults.removeObject(forKey: heroCatalogKey)
            }
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: profilesKey)
        // Still written for builds from before every server was used at once,
        // which read it to choose the one server they show.
        defaults.set(profiles.first?.id.uuidString, forKey: activeKey)
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    func restoreCloudSettings() async {
        isMDBListConnected = MDBListKeychainStore.apiKey() != nil
        guard let data = defaults.data(forKey: profilesKey),
              let saved = try? JSONDecoder().decode([MediaServerProfile].self, from: data) else { return }
        let known = Set(profiles.map(\.id))
        let kept = Set(saved.map(\.id))
        for gone in profiles where !kept.contains(gone.id) {
            servers[gone.id] = nil
            clients[gone.id] = nil
        }
        let arriving = saved.filter { !known.contains($0.id) }
        profiles = saved
        for profile in arriving { restoreLibrarySnapshot(for: profile, adoptingLists: false) }
        migrateLibraryChoices()
        selectedHeroCatalogID = savedHeroCatalogs()[Self.libraryWide]
        if !arriving.isEmpty { await reload(servers: arriving) }
    }
}

/// Whether opening the Media Servers tab should start a load for a server.
///
/// Four pieces of state decide it, and getting the combination wrong is not a
/// crash -- it is a tab that shows a spinner forever, or one that reloads the
/// whole library every time it is looked at. Both have happened, so the rule
/// lives somewhere a test can reach rather than inside the view.
enum MediaShelfLoad {
    static func shouldStart(profile: UUID, loaded: UUID?, alreadyRunning: Bool,
                            lastAttemptFailed: Bool) -> Bool {
        if alreadyRunning { return false }
        // A different provider than the one on screen always loads, whatever
        // happened to the last one.
        if loaded != profile { return true }
        // Same provider, already loaded: only worth doing again if the last
        // attempt did not finish. This is the retry, and it is why a viewer who
        // was on another network when the tab first opened gets their library
        // by returning to it rather than by relaunching the app.
        return lastAttemptFailed
    }
}
