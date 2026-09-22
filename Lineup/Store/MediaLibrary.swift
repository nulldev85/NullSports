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

    /// MDBList is an account-level discovery integration. Lists are offered in
    /// Add Shelf, then matched to titles that the active media server can
    /// actually play.
    @Published private(set) var mdbListAccount: MDBListAccount?
    @Published private(set) var mdbListCatalogs: [MDBListCatalog] = []
    @Published private(set) var isMDBListConnected = false
    @Published private(set) var isMDBListLoading = false

    @Published private(set) var isLoading = false
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
    // Written by a version that could install media sources the app talked to
    // directly. That feature is gone, so the state it left behind is cleared
    // on the next launch rather than sitting in defaults forever.
    private static let retiredKeys = ["Lineup.stremioAddons", "Lineup.stremioShelves"]
    private var loadID = UUID()
    /// The profile whose shelves are on screen, and the load that put them
    /// there. Both belong to the store rather than to the tab: a load owned by
    /// a view's task is cancelled the moment the viewer looks at another tab,
    /// which is most of a slow one.
    private var loadedProfileID: UUID?
    private var shelfLoad: Task<Void, Never>?
    /// Set when the last attempt ended without shelves, so the tab can say so
    /// and offer to try again instead of claiming there is nothing to show.
    @Published private(set) var loadFailed = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isMDBListConnected = MDBListKeychainStore.apiKey() != nil
        if let data = defaults.data(forKey: profilesKey),
           let saved = try? JSONDecoder().decode([MediaServerProfile].self, from: data) {
            profiles = saved
        }
        let activeID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        activeProfile = profiles.first { $0.id == activeID } ?? profiles.first
        if let data = defaults.data(forKey: localPlaybackKey),
           let saved = try? JSONDecoder().decode([LocalMediaPlayback].self, from: data) {
            localPlayback = saved
        }
        if let data = defaults.data(forKey: localFavoritesKey),
           let saved = try? JSONDecoder().decode([LocalMediaFavorite].self, from: data) {
            localFavorites = saved
        }
        for key in Self.retiredKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    var hasProfile: Bool { activeProfile != nil }

    /// Whether there is anything to show at all.
    var hasAnySource: Bool { activeProfile != nil }

    /// In-progress titles, newest first. A completed title belongs in History,
    /// not in Continue Watching, even if its final saved position is shy of the
    /// exact file duration.
    var continueWatching: [LocalMediaPlayback] {
        playbackForActiveProfile.filter { !$0.completed && $0.explicitlyUnwatched != true && $0.position >= 5 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Finished titles stay useful as a short, local history without taking
    /// over the Library. The stored collection itself is capped as well.
    var watchHistory: [LocalMediaPlayback] {
        playbackForActiveProfile.filter(\.completed).sorted { $0.updatedAt > $1.updatedAt }
    }

    var favoriteMedia: [MediaItem] {
        guard let profileID = activeProfile?.id else { return [] }
        return localFavorites.filter { $0.profileID == profileID }
            .sorted { $0.addedAt > $1.addedAt }.map(\.item)
    }

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
        loadedProfileID = nil
        loadFailed = false
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
        loadedProfileID = nil
        loadFailed = false
        MediaKeychainStore.delete(profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        localPlayback.removeAll { $0.profileID == profile.id }
        persistLocalPlayback()
        localFavorites.removeAll { $0.profileID == profile.id }
        persistLocalFavorites()
        saveMDBListShelfIDs([], profileID: profile.id)
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

    /// What the Media Servers tab asks for when it appears.
    ///
    /// Not `await`ed from the tab, and deliberately: the load is several
    /// requests deep and a viewer who switches tabs while it runs used to
    /// cancel it, come back, and find the work neither finished nor running.
    /// The store holds the task instead, so looking away costs nothing and
    /// looking back finds it done.
    ///
    /// It starts nothing when the shelves for this profile are already loaded,
    /// and starts again after an attempt that failed, which is the retry a
    /// viewer would otherwise have to find in a menu.
    func loadShelvesIfNeeded() {
        guard let profile = activeProfile else { return }
        guard MediaShelfLoad.shouldStart(profile: profile.id, loaded: loadedProfileID,
                                         alreadyRunning: shelfLoad != nil,
                                         lastAttemptFailed: loadFailed) else { return }
        shelfLoad = Task { [weak self] in
            await self?.reload()
            self?.shelfLoad = nil
        }
    }

    func reload() async {
        guard let profile = activeProfile else {
            roots = []; collections = []; catalogs = []; isLoading = false
            libraryCounts = nil; lastRefreshedAt = nil; isConnected = false
            loadedProfileID = nil; loadFailed = false
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
            let loadedCollections = ((try? await source.allCollections(userID: profile.userID)) ?? [])
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
            let loadedMDBListCatalogs = await loadSavedMDBListShelves(source: source, profile: profile)
            guard loadID == requestID, activeProfile?.id == profile.id else { return }
            roots = loaded
            collections = loadedCollections
            catalogs = loadedCatalogs + loadedMDBListCatalogs
            isConnected = true
            loadFailed = false
            loadedProfileID = profile.id
            lastRefreshedAt = Date()
            errorMessage = nil
            Task {
                let counts = try? await source.libraryCounts(userID: profile.userID)
                guard loadID == requestID, activeProfile?.id == profile.id else { return }
                libraryCounts = counts
            }
        } catch {
            guard loadID == requestID, activeProfile?.id == profile.id else { return }
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
            if !Self.isCancellation(error) {
                isConnected = false
                errorMessage = error.localizedDescription
            }
            loadFailed = true
            isLoading = false
            return
        }
        if loadID == requestID { isLoading = false }
        // After the libraries, not before: this is one request per enabled
        // catalog and the shelves should not wait behind it.
        if loadID == requestID { await loadAddonCatalogs() }
    }

    func items(in parent: MediaItem) async throws -> [MediaItem] {
        if Self.isMDBListShelfID(parent.id) {
            return catalogs.first { $0.id == parent.id }?.items ?? []
        }
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
            async let lists = source.lists()
            let loadedAccount = try await account
            let loadedLists = try await lists
            try MDBListKeychainStore.save(apiKey: cleanKey)
            mdbListAccount = loadedAccount
            mdbListCatalogs = loadedLists
            isMDBListConnected = true
            errorMessage = nil
            if let profileID = activeProfile?.id, !savedMDBListShelfIDs(for: profileID).isEmpty {
                await reload()
            }
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
            async let lists = source.lists()
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

    func disconnectMDBList() {
        MDBListKeychainStore.delete()
        mdbListAccount = nil
        mdbListCatalogs = []
        isMDBListConnected = false
        errorMessage = nil
        catalogs.removeAll { Self.isMDBListShelfID($0.id) }
        defaults.removeObject(forKey: mdbListShelvesKey)
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
    }

    var availableMDBListCatalogs: [MDBListCatalog] {
        mdbListCatalogs.filter { list in !catalogs.contains(where: { $0.id == list.shelfID }) }
    }

    // MARK: - Local playback tracking

    func localPlaybackRecord(for item: MediaItem) -> LocalMediaPlayback? {
        guard let profileID = activeProfile?.id else { return nil }
        return localPlayback.first { $0.profileID == profileID && $0.item.id == item.id }
    }

    /// The progress a card should present. Films and episodes match directly;
    /// a series poster represents the newest episode being watched in that
    /// show. Prefer an unfinished episode so a recently completed one never
    /// hides the actual place to continue.
    func displayedPlaybackRecord(for item: MediaItem) -> LocalMediaPlayback? {
        if let exact = localPlaybackRecord(for: item) {
            if exact.explicitlyUnwatched != true { return exact }
            if !item.isSeries { return nil }
        }
        guard item.isSeries else { return nil }
        let matches = playbackForActiveProfile.filter { record in
            guard record.item.type == "Episode", record.explicitlyUnwatched != true else { return false }
            if let seriesID = record.item.seriesID { return seriesID == item.id }
            return record.item.seriesName?.localizedCaseInsensitiveCompare(item.name) == .orderedSame
        }
        return matches.sorted { left, right in
            if left.completed != right.completed { return !left.completed }
            return left.updatedAt > right.updatedAt
        }.first
    }

    /// One consistent line under artwork throughout the Library.
    func playbackStatus(for item: MediaItem) -> String? {
        guard let record = displayedPlaybackRecord(for: item) else { return nil }
        let trackedItem = record.item
        let episodePrefix: String? = trackedItem.type == "Episode"
            ? "Season \(trackedItem.parentIndexNumber ?? 1), Episode \(trackedItem.indexNumber ?? 1)"
            : nil
        if record.completed {
            return episodePrefix.map { $0 + " · Watched" } ?? "Watched"
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
        guard let profileID = activeProfile?.id, position.isFinite, duration.isFinite,
              position >= 0, duration > 0 else { return }

        let safePosition = min(position, duration)
        // A title only becomes history after somebody has genuinely started it.
        // This also prevents opening and immediately closing a stream from
        // displacing something the viewer was actually watching.
        guard safePosition >= 5 else { return }
        let completed = LocalMediaTrackingPolicy.isComplete(position: safePosition, duration: duration)
        let record = LocalMediaPlayback(profileID: profileID, item: item,
            position: safePosition, duration: duration, updatedAt: Date(), completed: completed)
        if let index = localPlayback.firstIndex(where: { $0.id == record.id }) {
            localPlayback[index] = record
        } else {
            localPlayback.append(record)
        }
        // Keep plenty of useful history without letting artwork-rich item
        // records grow defaults forever. Each profile retains its newest 200.
        let retained = Dictionary(grouping: localPlayback, by: \.profileID).values.flatMap { records in
            records.sorted { $0.updatedAt > $1.updatedAt }.prefix(200)
        }
        localPlayback = Array(retained)
        persistLocalPlayback()
    }

    func clearLocalPlayback() {
        guard let profileID = activeProfile?.id else { return }
        localPlayback.removeAll { $0.profileID == profileID }
        persistLocalPlayback()
    }

    func isInContinueWatching(_ item: MediaItem) -> Bool {
        continueWatching.contains { $0.item.id == item.id }
    }

    /// Forget one resume point without telling the media server that the title
    /// was watched or unwatched. Playing it again naturally creates a fresh
    /// progress record.
    func removeFromContinueWatching(_ item: MediaItem) {
        guard let profileID = activeProfile?.id else { return }
        localPlayback.removeAll { $0.profileID == profileID && $0.item.id == item.id }
        persistLocalPlayback()
    }

    func isLocalFavorite(_ item: MediaItem) -> Bool {
        guard let profileID = activeProfile?.id else { return false }
        return localFavorites.contains { $0.profileID == profileID && $0.item.id == item.id }
    }

    func setLocalFavorite(_ favorite: Bool, for item: MediaItem) {
        guard let profileID = activeProfile?.id else { return }
        localFavorites.removeAll { $0.profileID == profileID && $0.item.id == item.id }
        if favorite {
            localFavorites.append(LocalMediaFavorite(profileID: profileID, item: item, addedAt: Date()))
        }
        persistLocalFavorites()
    }

    func setLocallyPlayed(_ played: Bool, for item: MediaItem) {
        guard let profileID = activeProfile?.id else { return }
        localPlayback.removeAll { $0.profileID == profileID && $0.item.id == item.id }
        let duration = item.runTimeTicks.map { max(1, Double($0) / 10_000_000) } ?? 1
        localPlayback.append(LocalMediaPlayback(profileID: profileID, item: item,
            position: played ? duration : 0, duration: duration, updatedAt: Date(),
            completed: played, explicitlyUnwatched: played ? nil : true))
        persistLocalPlayback()
    }

    func isWatched(_ item: MediaItem) -> Bool {
        if let local = localPlaybackRecord(for: item) {
            if local.explicitlyUnwatched == true { return false }
            if local.completed { return true }
        }
        return item.isPlayed
    }

    private var playbackForActiveProfile: [LocalMediaPlayback] {
        guard let profileID = activeProfile?.id else { return [] }
        return localPlayback.filter { $0.profileID == profileID }
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
        catch { if !Self.isCancellation(error) { errorMessage = error.localizedDescription } }
        catalogs.append(MediaCatalog(root: root, items: loaded))
        saveShelfIDs(catalogs.map(\.id).filter { !Self.isMDBListShelfID($0) }, profileID: profile.id)
    }

    func addMDBListShelf(_ list: MDBListCatalog) async {
        guard let profile = activeProfile,
              let apiKey = MDBListKeychainStore.apiKey(),
              !catalogs.contains(where: { $0.id == list.shelfID }) else { return }
        do {
            let source = try client(for: profile)
            async let entries = MDBListClient(apiKey: apiKey).items(in: list.id)
            async let serverTitles = source.allTitles(userID: profile.userID)
            let matched = MDBListCatalogMatcher.match(try await entries, to: try await serverTitles)
            catalogs.append(Self.mdbListShelf(list, items: matched))
            var ids = savedMDBListShelfIDs(for: profile.id)
            if !ids.contains(list.id) { ids.append(list.id) }
            saveMDBListShelfIDs(ids, profileID: profile.id)
            errorMessage = nil
        } catch {
            if !Self.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    func removeShelf(_ catalog: MediaCatalog) {
        guard let profile = activeProfile else { return }
        catalogs.removeAll { $0.id == catalog.id }
        saveShelfIDs(catalogs.map(\.id).filter { !Self.isMDBListShelfID($0) }, profileID: profile.id)
        if Self.isMDBListShelfID(catalog.id) {
            let ids = savedMDBListShelfIDs(for: profile.id).filter { "mdblist:\($0)" != catalog.id }
            saveMDBListShelfIDs(ids, profileID: profile.id)
        }
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
            if !addonsUnavailable, !Self.isCancellation(error) { errorMessage = error.localizedDescription }
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
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
            return
        }
        await waitForImport(of: catalog, addonID: addonID, profile: profile)
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
    private func waitForImport(of catalog: NullfinCatalog, addonID: String,
                               profile: MediaServerProfile) async {
        guard let source = try? client(for: profile) else { return }
        // A full library refresh re-imports every enabled catalog, not just
        // this one, so on a server with several addons it is minutes of work.
        // Ten of them. The first look happens before any waiting, because a
        // catalog the server already holds should not cost ten seconds.
        for attempt in 0..<61 {
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
            guard activeProfile?.id == profile.id else { return }
            guard let found = await importedCollection(for: catalog, addonID: addonID,
                                                       source: source, profile: profile)
            else { continue }
            await addShelf(found)
            drop(catalog)
            await reload()
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
        await reload()
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
            return item
        }
        let current = (try? await source.addonCatalogs(addonID: addonID))?
            .first { $0.catalogId == catalog.catalogId }
        if let id = current?.collectionId, id != catalog.collectionId,
           let item = try? await source.item(userID: profile.userID, itemID: id) {
            return item
        }
        return (try? await source.allCollections(userID: profile.userID))?
            .first { $0.name.caseInsensitiveCompare(catalog.name) == .orderedSame }
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

    private func loadSavedMDBListShelves(source: JellyfinClient,
                                         profile: MediaServerProfile) async -> [MediaCatalog] {
        let selected = savedMDBListShelfIDs(for: profile.id)
        guard !selected.isEmpty, let apiKey = MDBListKeychainStore.apiKey() else { return [] }
        do {
            let mdb = MDBListClient(apiKey: apiKey)
            let lists = try await mdb.lists()
            mdbListCatalogs = lists
            isMDBListConnected = true
            let inventory = try await source.allTitles(userID: profile.userID)
            let selectedLists = selected.compactMap { id in lists.first { $0.id == id } }
            return await withTaskGroup(of: (Int, MediaCatalog?).self) { group in
                for (index, list) in selectedLists.enumerated() {
                    group.addTask {
                        guard let entries = try? await mdb.items(in: list.id) else { return (index, nil) }
                        let matched = MDBListCatalogMatcher.match(entries, to: inventory)
                        return (index, Self.mdbListShelf(list, items: matched))
                    }
                }
                var loaded: [(Int, MediaCatalog)] = []
                for await (index, shelf) in group {
                    if let shelf { loaded.append((index, shelf)) }
                }
                return loaded.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        } catch {
            // MDBList being unavailable must never take the connected media
            // server or its own shelves down with it.
            return []
        }
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

    private func savedMDBListShelfIDs(for profileID: UUID) -> [Int] {
        savedMDBListShelves()[profileID.uuidString] ?? []
    }

    private func saveMDBListShelfIDs(_ ids: [Int], profileID: UUID) {
        var value = savedMDBListShelves()
        if ids.isEmpty { value.removeValue(forKey: profileID.uuidString) }
        else { value[profileID.uuidString] = ids }
        if value.isEmpty { defaults.removeObject(forKey: mdbListShelvesKey) }
        else { defaults.set(try? JSONEncoder().encode(value), forKey: mdbListShelvesKey) }
        if defaults === UserDefaults.standard { CloudSettingsSync.shared.localSettingsChanged() }
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
        isMDBListConnected = MDBListKeychainStore.apiKey() != nil
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

/// Whether opening the Media Servers tab should start a load.
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
