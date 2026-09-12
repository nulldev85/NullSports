import Foundation

/// Addons, talked to directly.
///
/// Lineup could already reach addon catalogs, but only the ones a Nullfin
/// server had been told to import: switch a catalog on, ask the server to
/// refresh, then wait minutes for it to walk the catalog and build a collection
/// -- and hope it finished. Everything in this file skips that. An addon is a
/// public JSON API, so a row is one request away and a stream is one more.
///
/// None of it replaces the server. A server holds a library that is actually
/// yours and this does not; the two sit side by side, and a shelf from either
/// looks and behaves the same because both arrive as `MediaItem`s.
extension MediaLibrary {

    // MARK: - Installing

    /// Read the addons back at launch. Stored whole rather than as addresses,
    /// so the Media Servers tab can list what each one offers without asking
    /// every addon for its manifest before it can draw anything.
    func restoreAddons() {
        guard let data = defaults.data(forKey: addonsKey),
              let saved = try? JSONDecoder().decode([StremioAddon].self, from: data) else { return }
        addons = saved
    }

    /// Add an addon from the link the viewer pasted.
    ///
    /// The manifest is the check: an address that answers with one is an
    /// addon, and an address that does not is a web page, a typo, or a server.
    /// Adding one already installed replaces it, which is also how an addon is
    /// updated after its catalogs change.
    func addAddon(address: String) async -> Bool {
        addonBusy = true
        defer { addonBusy = false }
        do {
            let base = try StremioClient.base(from: address)
            let client = try StremioClient(address: base.absoluteString)
            let manifest = try await client.manifest()
            guard manifest.providesCatalogs || manifest.providesStreams else {
                throw StremioError.notAnAddon
            }
            let addon = StremioAddon(manifest: manifest, address: base.absoluteString)
            addons.removeAll { $0.id == addon.id }
            addons.append(addon)
            persistAddons()
            // An addon that is added and then shows nothing looks broken. Its
            // first rows go up by themselves, and any of them can be taken off
            // again from the shelf it lands on.
            let opening = addon.catalogs.prefix(2)
            for catalog in opening where !addonShelfIDs.contains(StremioID.shelf(addon: addon.id, catalog: catalog)) {
                addonShelfIDs.append(StremioID.shelf(addon: addon.id, catalog: catalog))
            }
            persistAddonShelves()
            await refreshAddonShelves()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Remove an addon and every row that came from it. Its rows are its own:
    /// leaving them behind would leave shelves nothing can refill.
    func removeAddon(_ addon: StremioAddon) {
        addons.removeAll { $0.id == addon.id }
        addonShelfIDs.removeAll { $0.hasPrefix("addon:\(addon.id)|") }
        addonShelves.removeAll { $0.root.addonID == addon.id }
        addonMetas = addonMetas.filter { !$0.key.hasPrefix("\(addon.id)|") }
        persistAddons()
        persistAddonShelves()
    }

    // MARK: - Rows

    /// Fetch every chosen row again, in the order they were chosen.
    ///
    /// A row that will not load stays on screen empty rather than disappearing:
    /// an addon that is down for a minute should not silently cost the viewer
    /// the shelf they picked.
    func refreshAddonShelves() async {
        let wanted = addonShelfIDs.compactMap(resolveShelf)
        guard !wanted.isEmpty else { addonShelves = []; return }
        let loaded = await withTaskGroup(of: (Int, MediaCatalog).self) { group in
            for (index, entry) in wanted.enumerated() {
                group.addTask {
                    let root = MediaItem(catalog: entry.catalog, addon: entry.addon)
                    let metas = (try? await StremioClient(address: entry.addon.address)
                        .catalog(type: entry.catalog.type, id: entry.catalog.id)) ?? []
                    let items = metas.map { MediaItem(meta: $0, addonID: entry.addon.id) }
                    return (index, MediaCatalog(root: root, items: items))
                }
            }
            var result: [(Int, MediaCatalog)] = []
            for await value in group { result.append(value) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
        addonShelves = loaded
    }

    /// The catalogs every installed addon offers that are not already a row.
    var availableAddonCatalogs: [(addon: StremioAddon, catalogs: [StremioCatalogSpec])] {
        addons.compactMap { addon in
            let free = addon.catalogs.filter {
                !addonShelfIDs.contains(StremioID.shelf(addon: addon.id, catalog: $0))
            }
            return free.isEmpty ? nil : (addon: addon, catalogs: free)
        }
    }

    /// Put a catalog on screen. One request, and it is a row -- which is the
    /// whole difference between this and asking a server to import it.
    func addAddonShelf(_ catalog: StremioCatalogSpec, addon: StremioAddon) async {
        let id = StremioID.shelf(addon: addon.id, catalog: catalog)
        guard !addonShelfIDs.contains(id) else { return }
        addonShelfIDs.append(id)
        persistAddonShelves()
        let root = MediaItem(catalog: catalog, addon: addon)
        var items: [MediaItem] = []
        do {
            items = try await StremioClient(address: addon.address)
                .catalog(type: catalog.type, id: catalog.id)
                .map { MediaItem(meta: $0, addonID: addon.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
        guard addonShelfIDs.contains(id) else { return }
        addonShelves.append(MediaCatalog(root: root, items: items))
    }

    func removeAddonShelf(_ catalog: MediaCatalog) {
        addonShelfIDs.removeAll { $0 == catalog.id }
        addonShelves.removeAll { $0.id == catalog.id }
        persistAddonShelves()
    }

    // MARK: - Browsing

    /// What is inside a row, or inside a series, as the screens ask for it.
    func addonItems(in parent: MediaItem) async throws -> [MediaItem] {
        guard let addon = self.addon(parent.addonID) else { return [] }
        if parent.type == "CollectionFolder" {
            guard let type = parent.stremioType, let id = parent.stremioID else { return [] }
            return try await StremioClient(address: addon.address)
                .catalog(type: type, id: id)
                .map { MediaItem(meta: $0, addonID: addon.id) }
        }
        return try await addonChildren(of: parent)
    }

    /// A series' seasons, or a season's episodes.
    ///
    /// An addon hands back every episode of a series in one flat list, so the
    /// seasons are read out of that list rather than fetched. A series with one
    /// season is given straight to the screen as episodes: a lone "Season 1"
    /// row to click through is a step for nothing.
    func addonChildren(of parent: MediaItem) async throws -> [MediaItem] {
        guard let addonID = parent.addonID,
              let record = await self.meta(for: parent) else { return [] }
        let videos = record.videos ?? []
        guard !videos.isEmpty else { return [] }
        if parent.type == "Season" {
            let wanted = parent.indexNumber ?? 1
            return videos.filter { ($0.season ?? 1) == wanted }
                .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
                .map { MediaItem(video: $0, in: record, addonID: addonID) }
        }
        let numbers = Set(videos.map { $0.season ?? 1 })
        guard numbers.count > 1 else {
            return videos.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
                .map { MediaItem(video: $0, in: record, addonID: addonID) }
        }
        // Specials are season zero and belong at the end, not the front.
        return numbers.sorted { left, right in
            if left == 0 { return false }
            if right == 0 { return true }
            return left < right
        }.map { number in
            MediaItem(season: number, of: record, addonID: addonID,
                      episodes: videos.filter { ($0.season ?? 1) == number }.count)
        }
    }

    /// The full record, which for a card is most of what it already has and for
    /// a show page is the description, the cast of facts and the episodes.
    func addonDetails(of item: MediaItem) async throws -> MediaItem {
        guard let addonID = item.addonID,
              let record = await self.meta(for: item) else { return item }
        return MediaItem(meta: record, addonID: addonID)
    }

    // MARK: - Streams

    /// Every playable stream for one thing, from every addon that offers them.
    ///
    /// Not only the addon the item came from: catalogs and streams are separate
    /// jobs in this protocol, and the usual arrangement is one addon for the
    /// rows and another for the links. Asking all of them is what makes a
    /// catalogue addon's film playable at all.
    func addonSources(for item: MediaItem) async throws -> [MediaPlaybackSource] {
        guard let type = item.stremioType, let id = item.stremioID else { return [] }
        let asked = addons.filter { $0.streams(for: type) }
        guard !asked.isEmpty else { throw StremioStreamsUnavailable.noStreamAddon }
        let answers = await withTaskGroup(of: (Int, StremioAddon, [StremioStream]).self) { group in
            for (index, addon) in asked.enumerated() {
                group.addTask {
                    let streams = (try? await StremioClient(address: addon.address)
                        .streams(type: type, id: id)) ?? []
                    return (index, addon, streams)
                }
            }
            var result: [(Int, StremioAddon, [StremioStream])] = []
            for await value in group { result.append(value) }
            return result.sorted { $0.0 < $1.0 }
        }
        var sources: [MediaPlaybackSource] = []
        var unplayable = 0
        for (_, addon, streams) in answers {
            for stream in streams where !stream.isPlayable { unplayable += 1 }
            for (index, stream) in streams.filter(\.isPlayable).enumerated() {
                sources.append(MediaPlaybackSource(stream: stream, addon: addon, index: index))
            }
        }
        // A result that cannot be played is worth saying out loud. Torrents are
        // the common case and they need an engine this app does not have, so a
        // silent empty list would look like the addons found nothing at all
        // when in fact they found plenty of the wrong kind.
        if sources.isEmpty && unplayable > 0 { throw StremioStreamsUnavailable.linksOnly(unplayable) }
        return sources
    }

    // MARK: - Search

    /// Ask every addon that takes a search term. Two catalogs each at most:
    /// a metadata addon offers one per type and this should stay one round of
    /// requests rather than a dozen.
    func searchAddons(_ query: String) async -> [MediaItem] {
        let asked = addons.flatMap { addon in
            addon.searchable.prefix(2).map { (addon, $0) }
        }
        guard !asked.isEmpty else { return [] }
        let found = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, entry) in asked.enumerated() {
                let (addon, catalog) = entry
                group.addTask {
                    let metas = (try? await StremioClient(address: addon.address)
                        .catalog(type: catalog.type, id: catalog.id,
                                 extra: [("search", query)])) ?? []
                    return (index, metas.map { MediaItem(meta: $0, addonID: addon.id) })
                }
            }
            var result: [(Int, [MediaItem])] = []
            for await value in group { result.append(value) }
            return result.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Plumbing

    func addon(_ id: String?) -> StremioAddon? {
        guard let id else { return nil }
        return addons.first { $0.id == id }
    }

    /// The addon's own record for an item, kept once fetched.
    ///
    /// The addon that supplied the row is asked first and anything else that
    /// answers about this kind of thing after it, because plenty of catalog
    /// addons hand out ids they cannot describe -- they are imdb ids, and a
    /// metadata addon is what describes those.
    private func meta(for item: MediaItem) async -> StremioMeta? {
        guard let addonID = item.addonID, let type = item.stremioType,
              let id = item.stremioID else { return nil }
        let key = "\(addonID)|\(id)"
        if let cached = addonMetas[key] { return cached }
        var order: [StremioAddon] = []
        if let own = addon(addonID), own.providesMeta { order.append(own) }
        order += addons.filter {
            $0.id != addonID && $0.providesMeta && ($0.types.isEmpty || $0.types.contains(type))
        }
        for source in order {
            guard let client = try? StremioClient(address: source.address),
                  let meta = try? await client.meta(type: type, id: id) else { continue }
            addonMetas[key] = meta
            return meta
        }
        return nil
    }

    private func resolveShelf(_ id: String) -> (addon: StremioAddon, catalog: StremioCatalogSpec)? {
        for addon in addons {
            if let catalog = addon.catalogs.first(where: {
                StremioID.shelf(addon: addon.id, catalog: $0) == id
            }) { return (addon, catalog) }
        }
        return nil
    }

    private func persistAddons() {
        defaults.set(try? JSONEncoder().encode(addons), forKey: addonsKey)
    }

    private func persistAddonShelves() {
        defaults.set(addonShelfIDs, forKey: addonShelvesKey)
    }
}

/// Why a thing an addon listed cannot be watched. Both of these are ordinary
/// answers rather than faults, and both are worth saying in full: "no streams"
/// on its own sends someone looking for a problem that is not there.
enum StremioStreamsUnavailable: LocalizedError {
    case noStreamAddon
    case linksOnly(Int)

    var errorDescription: String? {
        switch self {
        case .noStreamAddon:
            return "None of your addons provide streams. Add a streaming addon to play what your catalog addons list."
        case .linksOnly(let count):
            return "\(count) result\(count == 1 ? "" : "s") came back, but all of them are torrents or links this app cannot open. A streaming addon that returns direct links will play here."
        }
    }
}
