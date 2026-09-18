import Foundation

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var profiles: [MediaServerProfile] = []
    @Published private(set) var activeProfile: MediaServerProfile?
    /// The server's own libraries, as `/views` reports them.
    @Published private(set) var roots: [MediaItem] = []
    /// Collections, which on a Nullfin server is where an enabled addon catalog
    /// lands. Kept apart from `roots` only so the shelf picker can say which is
    /// which; a shelf made from either behaves the same way.
    @Published private(set) var collections: [MediaItem] = []
    /// Collections named by the addons themselves, resolved one id at a time.
    ///
    /// The list of every collection is a broad query with a lot of assumptions
    /// in it. An addon says outright which catalogs it has switched on and what
    /// each one's collection is, and asking for one item by its id is the
    /// narrowest question there is. Where the two disagree this one is right,
    /// so both are merged and this one is the reason a catalog appears at all
    /// when the broad query comes back short.
    @Published private(set) var importedCatalogs: [MediaItem] = []
    @Published private(set) var catalogs: [MediaCatalog] = []
    @Published private(set) var libraryCounts: MediaLibraryCounts?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var isConnected = false
    /// Catalogs each addon offers that the server is not importing yet. Loaded
    /// on demand, because the routes behind it are administrator-only and a
    /// server may refuse them.
    @Published private(set) var addonGroups: [AddonCatalogGroup] = []
    /// Catalogs switched on and waiting for the server to finish importing.
    @Published private(set) var importing: Set<String> = []
    /// Set when the server will not discuss addons with this account, so the
    /// screen can say why rather than showing an empty list.
    @Published private(set) var addonsUnavailable = false
    private var importTasks: [String: Task<Void, Never>] = [:]

    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    // Named for the app's old name on purpose: this is where existing installs
    // already keep their data, and renaming the key would hide it from them.
    private let profilesKey = "NullSports.mediaServers"
    private let activeKey = "NullSports.activeMediaServer"
    private let deviceKey = "NullSports.mediaDeviceID"
    private let shelvesKey = "NullSports.mediaShelves"
    // Written by a version that could install media sources the app talked to
    // directly. That feature is gone, so the state it left behind is cleared
    // on the next launch rather than sitting in defaults forever.
    private static let retiredKeys = ["Lineup.stremioAddons", "Lineup.stremioShelves"]
    private var loadID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: profilesKey),
           let saved = try? JSONDecoder().decode([MediaServerProfile].self, from: data) {
            profiles = saved
        }
        let activeID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        activeProfile = profiles.first { $0.id == activeID } ?? profiles.first
        for key in Self.retiredKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    var hasProfile: Bool { activeProfile != nil }

    /// Whether there is anything to show at all.
    var hasAnySource: Bool { activeProfile != nil }

    /// Every row on the Media Servers tab.
    var shelves: [MediaCatalog] { catalogs }

    func addServer(name: String, serverURL: String, username: String, password: String) async -> Bool {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the user name is required. A Jellyfin-compatible server may have
        // no password set on the account, and the server itself is the right
        // judge of whether the credentials it was handed are good enough.
        guard !cleanUsername.isEmpty else {
            errorMessage = "Enter your media server user name."
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let client = try JellyfinClient(serverURL: serverURL, deviceID: deviceID)
            let authentication = try await client.authenticate(username: cleanUsername, password: password)
            let profile = MediaServerProfile(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Media" : name,
                serverURL: client.serverURL.absoluteString,
                username: authentication.user.name,
                userID: authentication.user.id
            )
            try MediaKeychainStore.save(token: authentication.accessToken, profileID: profile.id)
            profiles.append(profile)
            activeProfile = profile
            persist()
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func select(_ profile: MediaServerProfile) async {
        loadID = UUID()
        activeProfile = profile
        roots = []
        collections = []
        catalogs = []
        libraryCounts = nil
        lastRefreshedAt = nil
        isConnected = false
        persist()
        await reload()
    }

    func remove(_ profile: MediaServerProfile) {
        loadID = UUID()
        MediaKeychainStore.delete(profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        if activeProfile?.id == profile.id {
            activeProfile = profiles.first
            roots = []
            collections = []
            catalogs = []
            libraryCounts = nil
            lastRefreshedAt = nil
            isConnected = false
        }
        isLoading = false
        persist()
        if activeProfile != nil { Task { await reload() } }
    }

    func reload() async {
        guard let profile = activeProfile else {
            roots = []; collections = []; catalogs = []; isLoading = false
            libraryCounts = nil; lastRefreshedAt = nil; isConnected = false
            return
        }
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        isConnected = false
        libraryCounts = nil
        errorMessage = nil
        do {
            let source = try client(for: profile)
            let loaded = try await source.views(userID: profile.userID)
            // A server with no collections answers with an empty list, and one
            // too old to know the route answers an error. Neither is worth
            // costing the viewer the libraries that did load.
            // The BoxSet filter matches on the server's own kind, not on the
            // type it reports, so a promoted collection comes back here as well
            // as in the views above. Whatever a library already offers is the
            // library's.
            let known = Set(loaded.map(\.id))
            let loadedCollections = ((try? await source.collections(userID: profile.userID)) ?? [])
                .filter { !known.contains($0.id) }
            let shelvable = loaded + loadedCollections
            let selectedRoots = selectedShelfRoots(from: shelvable, profileID: profile.id)
            let loadedCatalogs = await withTaskGroup(of: MediaCatalog.self) { group in
                for root in selectedRoots {
                    group.addTask {
                        let items = (try? await source.items(userID: profile.userID, parentID: root.id)) ?? []
                        return MediaCatalog(root: root, items: items)
                    }
                }
                var result: [MediaCatalog] = []
                for await catalog in group { result.append(catalog) }
                return result.sorted { left, right in
                    let leftIndex = shelvable.firstIndex { $0.id == left.id } ?? .max
                    let rightIndex = shelvable.firstIndex { $0.id == right.id } ?? .max
                    return leftIndex < rightIndex
                }
            }
            guard loadID == requestID, activeProfile?.id == profile.id else { return }
            roots = loaded
            collections = loadedCollections
            catalogs = loadedCatalogs
            isConnected = true
            lastRefreshedAt = Date()
            errorMessage = nil
            Task {
                let counts = try? await source.libraryCounts(userID: profile.userID)
                guard loadID == requestID, activeProfile?.id == profile.id else { return }
                libraryCounts = counts
            }
        } catch {
            guard loadID == requestID, activeProfile?.id == profile.id else { return }
            isConnected = false
            errorMessage = error.localizedDescription
        }
        if loadID == requestID { isLoading = false }
        // After the libraries, not before: this is one request per enabled
        // catalog and the shelves should not wait behind it.
        if loadID == requestID { await loadAddonCatalogs() }
    }

    func items(in parent: MediaItem) async throws -> [MediaItem] {
        guard let profile = activeProfile else { return [] }
        return try await client(for: profile).items(userID: profile.userID, parentID: parent.id)
    }

    // Seasons and episodes are numbered, not named: "Season 10" sorts before
    // "Season 2" by name. A season can also run long past the shelf's limit.
    func numberedChildren(of parent: MediaItem) async throws -> [MediaItem] {
        guard let profile = activeProfile else { return [] }
        return try await client(for: profile).items(userID: profile.userID,
            parentID: parent.id, sortBy: "IndexNumber", limit: 500)
    }

    /// The full record for an item. A shelf card carries only what a shelf needs.
    func details(of item: MediaItem) async throws -> MediaItem {
        guard let profile = activeProfile else { return item }
        return try await client(for: profile).item(userID: profile.userID, itemID: item.id)
    }

    func related(to item: MediaItem) async -> [MediaItem] {
        let genres = Set((item.genres ?? []).map { $0.lowercased() })
        let local = shelves.flatMap(\.items).filter { candidate in
            candidate.hasDetailPage && candidate.type == item.type
                && candidate.id != item.id
                && !genres.isEmpty
                && !genres.isDisjoint(with: Set((candidate.genres ?? []).map { $0.lowercased() }))
        }.sorted { left, right in
            let leftMatch = genres.intersection(Set((left.genres ?? []).map { $0.lowercased() })).count
            let rightMatch = genres.intersection(Set((right.genres ?? []).map { $0.lowercased() })).count
            return leftMatch > rightMatch
        }
        var remote: [MediaItem] = []
        if let profile = activeProfile {
            remote = (try? await client(for: profile)
                .similarItems(userID: profile.userID, itemID: item.id))?
                .filter { $0.id != item.id && $0.hasDetailPage } ?? []
        }
        // Server recommendations can be empty or unavailable. Shelved movies
        // of matching genres keep the Related row useful on either platform.
        var seen: Set<String> = []
        return (remote + local).filter { candidate in
            let key = "\(candidate.name.lowercased())|\(candidate.productionYear ?? 0)"
            return seen.insert(key).inserted
        }.prefix(16).map { $0 }
    }

    func personImageURL(for person: MediaPerson, width: Int = 300) -> URL? {
        guard person.primaryImageTag != nil, let personID = person.personID,
              let profile = activeProfile else { return nil }
        return try? client(for: profile)
            .imageURL(itemID: personID, type: "primary", maxWidth: width)
    }

    func nextUp(in series: MediaItem) async -> MediaItem? {
        guard let profile = activeProfile else { return nil }
        return try? await client(for: profile)
            .nextUp(userID: profile.userID, seriesID: series.id).first
    }

    /// Per-source scores, when the server keeps them. A Jellyfin server does
    /// not, so a failure here means "show what the item itself carries".
    func metrics(for item: MediaItem) async -> [MediaMetric] {
        guard let profile = activeProfile else { return [] }
        return (try? await client(for: profile).itemMetrics(itemID: item.id)) ?? []
    }

    func setFavorite(_ isFavorite: Bool, for item: MediaItem) async {
        guard let profile = activeProfile else { return }
        do {
            try await client(for: profile)
                .setFavorite(userID: profile.userID, itemID: item.id, isFavorite: isFavorite)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setPlayed(_ isPlayed: Bool, for item: MediaItem) async {
        guard let profile = activeProfile else { return }
        do {
            try await client(for: profile)
                .setPlayed(userID: profile.userID, itemID: item.id, isPlayed: isPlayed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Search the server, with what is already shelved as the fallback.
    ///
    /// The server's own results come first, because those are titles the viewer
    /// actually holds. A server that fails still leaves the loaded shelves
    /// searchable, and only an empty result raises the error.
    func search(_ query: String) async throws -> [MediaItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        // A loaded shelf stays searchable on its own; the server expands
        // beyond those first-page cards.
        var results = shelves.flatMap(\.items).filter {
            $0.hasDetailPage && $0.name.localizedStandardContains(term)
        }
        var serverError: Error?
        if let profile = activeProfile {
            do {
                results = try await client(for: profile)
                    .search(userID: profile.userID, query: term) + results
            } catch { serverError = error }
        }
        var seen: Set<String> = []
        results = results.filter { seen.insert($0.id).inserted }
        if results.isEmpty, let serverError { throw serverError }
        return results
    }

    /// Add a shelf for a library or collection.
    ///
    /// A shelf whose contents will not load is still added, empty. It was
    /// asked for by name, and a row with a title and nothing under it can be
    /// seen, understood and removed; a choice that quietly does nothing cannot.
    func addShelf(_ root: MediaItem) async {
        guard let profile = activeProfile, !catalogs.contains(where: { $0.id == root.id }) else { return }
        var loaded: [MediaItem] = []
        do { loaded = try await client(for: profile).items(userID: profile.userID, parentID: root.id) }
        catch { errorMessage = error.localizedDescription }
        catalogs.append(MediaCatalog(root: root, items: loaded))
        saveShelfIDs(catalogs.map(\.id), profileID: profile.id)
    }

    func removeShelf(_ catalog: MediaCatalog) {
        guard let profile = activeProfile else { return }
        catalogs.removeAll { $0.id == catalog.id }
        saveShelfIDs(catalogs.map(\.id), profileID: profile.id)
    }

    var availableShelves: [MediaItem] { availableLibraries + availableCatalogs }

    /// The server's own libraries that are not already a shelf.
    var availableLibraries: [MediaItem] { unshelved(roots) }

    /// The imported catalogs, and any hand-made collection, that are not
    /// already a shelf. On a Nullfin server this is the list the viewer came for.
    var availableCatalogs: [MediaItem] {
        var seen: Set<String> = []
        return unshelved(importedCatalogs + collections)
            .filter { seen.insert($0.id).inserted }
    }

    private func unshelved(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { item in !catalogs.contains(where: { $0.id == item.id }) }
    }

    // MARK: - Addon catalogs

    /// What each addon offers that the server is not importing yet.
    ///
    /// A catalog arrives switched off, and the server only imports the ones
    /// switched on -- so adding an addon puts nothing in the library by
    /// itself, which is why a newly added addon appeared to do nothing here.
    /// Already-enabled catalogs are left out: those are collections, and the
    /// shelf list above already offers them.
    func loadAddonCatalogs() async {
        guard let profile = activeProfile, let source = try? client(for: profile) else { return }
        do {
            let addons = try await source.addons().filter(\.enabled)
            var groups: [AddonCatalogGroup] = []
            var imported: [MediaItem] = []
            for addon in addons {
                let offered = (try? await source.addonCatalogs(addonID: addon.id)) ?? []
                let available = offered.filter { !$0.enabled }
                if !available.isEmpty {
                    groups.append(AddonCatalogGroup(id: addon.id, name: addon.name, catalogs: available))
                }
                // A catalog already switched on has a collection waiting, and
                // the addon has just named it. Ask for that one item rather
                // than hoping it turns up in a list of everything.
                for enabled in offered where enabled.enabled {
                    guard let id = enabled.collectionId else { continue }
                    guard let item = try? await source.item(userID: profile.userID, itemID: id) else { continue }
                    imported.append(item)
                }
            }
            guard activeProfile?.id == profile.id else { return }
            addonGroups = groups
            importedCatalogs = imported
            addonsUnavailable = false
        } catch {
            guard activeProfile?.id == profile.id else { return }
            addonGroups = []
            importedCatalogs = []
            // Anything but a refusal is worth reporting; a refusal is the
            // ordinary answer from a plain Jellyfin server or a member account.
            addonsUnavailable = isRefusal(error)
            if !addonsUnavailable { errorMessage = error.localizedDescription }
        }
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
    func enableCatalog(_ catalog: NullfinCatalog, addonID: String) {
        guard activeProfile != nil, importTasks[catalog.catalogId] == nil else { return }
        importing.insert(catalog.catalogId)
        importTasks[catalog.catalogId] = Task { @MainActor [weak self] in
            await self?.runImport(of: catalog, addonID: addonID)
            self?.importTasks[catalog.catalogId] = nil
            self?.importing.remove(catalog.catalogId)
        }
    }

    /// Stop waiting on an import. The server keeps going: this only gives up
    /// watching for it, which is the difference between a screen that can be
    /// left and one that holds someone there.
    func stopWaiting(for catalog: NullfinCatalog) {
        importTasks[catalog.catalogId]?.cancel()
    }

    private func runImport(of catalog: NullfinCatalog, addonID: String) async {
        guard let profile = activeProfile, let source = try? client(for: profile) else { return }
        do {
            try await source.setCatalog(addonID: addonID, catalogID: catalog.catalogId, enabled: true)
            try await source.refreshLibrary()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await waitForImport(of: catalog, profile: profile)
    }

    private func drop(_ catalog: NullfinCatalog) {
        addonGroups = addonGroups.compactMap { group in
            let rest = group.catalogs.filter { $0.catalogId != catalog.catalogId }
            return rest.isEmpty ? nil : AddonCatalogGroup(id: group.id, name: group.name, catalogs: rest)
        }
    }

    /// Poll until the catalog's collection turns up, then shelve it.
    ///
    /// The server gives no signal when one catalog is done, so the collection
    /// appearing is the signal. It gives up after a few minutes rather than
    /// waiting forever; the shelf can still be added by hand once the import
    /// finishes.
    private func waitForImport(of catalog: NullfinCatalog, profile: MediaServerProfile) async {
        guard let source = try? client(for: profile) else { return }
        guard let wanted = catalog.collectionId else {
            // Without an id there is nothing to watch for. It is switched on
            // either way, so say so rather than leaving the choice looking
            // like it did nothing.
            errorMessage = "\(catalog.name) is switched on, but this server did not say which collection it becomes. It will appear under imported catalogs once the server finishes."
            return
        }
        // Ask for the one collection by the id the addon just named, rather
        // than scanning a list of every collection for it. A list is a broad
        // query with assumptions in it and it only has to be wrong once to
        // leave this waiting forever; an item by its id either exists or does
        // not. The first look happens before any waiting, because a catalog
        // the server already holds should not cost ten seconds.
        //
        // A full library refresh re-imports every enabled catalog, not just
        // this one, so on a server with several addons it is minutes of work.
        // Ten of them.
        for attempt in 0..<61 {
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
            guard activeProfile?.id == profile.id else { return }
            guard let found = try? await source.item(userID: profile.userID, itemID: wanted)
            else { continue }
            await addShelf(found)
            drop(catalog)
            await reload()
            return
        }
        // Out of patience, not out of luck: the server is still working and
        // the catalog is still enabled. Put it where it will turn up.
        guard !Task.isCancelled else { return }
        errorMessage = "\(catalog.name) is still importing on the server. It will appear under imported catalogs when that finishes — refresh then to add it."
        await reload()
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

    func imageURL(for item: MediaItem, width: Int = 600) -> URL? {
        // A source that names its artwork outright is asked for that address
        // directly, and the server is never reached at all.
        if let poster = item.posterURL { return URL(string: poster) }
        guard let profile = activeProfile else { return nil }
        return try? client(for: profile).imageURL(itemID: item.id, maxWidth: width)
    }

    // Asking for art the server did not report leaves a request to 404 behind
    // every hero, so each of these answers nil unless the item claims one.
    func backdropURL(for item: MediaItem, width: Int = 1280) -> URL? {
        if let backdrop = item.backdropURL { return URL(string: backdrop) }
        guard item.hasBackdrop, let profile = activeProfile else { return nil }
        return try? client(for: profile).imageURL(itemID: item.id, type: "backdrop", maxWidth: width)
    }

    func logoURL(for item: MediaItem, width: Int = 800) -> URL? {
        if let logo = item.logoArtworkURL { return URL(string: logo) }
        guard item.hasLogo, let profile = activeProfile else { return nil }
        return try? client(for: profile).imageURL(itemID: item.id, type: "logo", maxWidth: width)
    }

    func playbackURL(for item: MediaItem) -> URL? {
        guard let profile = activeProfile else { return nil }
        return try? client(for: profile).playbackURL(itemID: item.id)
    }

    private var deviceID: String {
        if let existing = defaults.string(forKey: deviceKey) { return existing }
        let value = UUID().uuidString
        defaults.set(value, forKey: deviceKey)
        return value
    }

    private func client(for profile: MediaServerProfile) throws -> JellyfinClient {
        guard let token = MediaKeychainStore.token(profileID: profile.id) else {
            throw JellyfinError.authenticationFailed
        }
        return try JellyfinClient(serverURL: profile.serverURL, accessToken: token, deviceID: deviceID)
    }

    func playbackSources(for item: MediaItem) async throws -> [MediaPlaybackSource] {
        guard let profile = activeProfile else { return [] }
        return try await client(for: profile).playbackInfo(itemID: item.id).mediaSources
            .filter { $0.path != "/videos/no-streams" && $0.name != "No streams found" }
    }

    func playbackURL(for item: MediaItem, source: MediaPlaybackSource) -> URL? {
        guard let profile = activeProfile else { return nil }
        return try? client(for: profile).playbackURL(itemID: item.id, mediaSourceID: source.id)
    }

    /// One addon and the catalogs it offers that are not switched on yet.
    struct AddonCatalogGroup: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let catalogs: [NullfinCatalog]
    }

    private func selectedShelfRoots(from roots: [MediaItem], profileID: UUID) -> [MediaItem] {
        let selections = savedShelves()
        if let saved = selections[profileID.uuidString] {
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
        let defaults = [movie, series].compactMap { $0 }
        saveShelfIDs(defaults.map(\.id), profileID: profileID)
        return defaults
    }

    private func savedShelves() -> [String: [String]] {
        guard let data = defaults.data(forKey: shelvesKey),
              let value = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return value
    }

    private func saveShelfIDs(_ ids: [String], profileID: UUID) {
        var value = savedShelves()
        value[profileID.uuidString] = ids
        defaults.set(try? JSONEncoder().encode(value), forKey: shelvesKey)
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: profilesKey)
        defaults.set(activeProfile?.id.uuidString, forKey: activeKey)
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    func restoreCloudSettings() async {
        guard let data = defaults.data(forKey: profilesKey),
              let saved = try? JSONDecoder().decode([MediaServerProfile].self, from: data) else { return }
        let activeID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        profiles = saved
        let selected = saved.first { $0.id == activeID } ?? saved.first
        if selected?.id != activeProfile?.id {
            activeProfile = selected
            roots = []
            catalogs = []
            if selected != nil { await reload() }
        } else {
            activeProfile = selected
        }
    }
}
