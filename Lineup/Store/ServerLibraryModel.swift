import Foundation
import Observation

/// One server's own Library while it is on screen: which of its libraries is
/// showing, and that library's Recommended rows, its titles and its
/// collections.
///
/// Kept by the store for as long as the server is connected, so going back
/// to it is instant, and saved to the device, so the first look after a
/// launch draws at once from what was there last time. What is on screen is
/// then read again quietly and replaced only when the answer arrives; a
/// failure leaves it as it was. Once the page in view has loaded, the other
/// two are read behind it, so changing page shows what is already there.
@MainActor
@Observable
final class ServerLibraryModel {
    enum Tab: String, CaseIterable, Identifiable {
        case recommended, library, collections
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recommended: "Recommended"
            case .library: "Library"
            case .collections: "Collections"
            }
        }
    }

    /// How far a page has got. A page that has something to show is
    /// `loaded`, whether or not it is being read again behind it.
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    let profile: MediaServerProfile
    @ObservationIgnored private let browser: any ServerLibraryBrowsing
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var libraries: [MediaItem] = []
    private(set) var librariesPhase: Phase = .idle
    private(set) var library: MediaItem?
    var tab: Tab = .recommended {
        didSet { if tab != oldValue { Task { await loadTab(tab) } } }
    }

    private(set) var home = ServerLibraryHome()
    private(set) var homePhase: Phase = .idle

    private(set) var titles: [MediaItem] = []
    private(set) var titlesTotal: Int?
    private(set) var titlesPhase: Phase = .idle
    @ObservationIgnored private var titlesNext: String?
    private(set) var loadingMore = false
    private(set) var browse: ServerLibraryBrowse

    private(set) var collections: [ServerLibraryCollection] = []
    private(set) var collectionsPhase: Phase = .idle

    private(set) var genres: [String] = []
    /// What each title's card says about its file, from every list read.
    private(set) var badges: [String: ServerLibraryBadges] = [:]

    /// Which library, and which order of it, is showing, so an answer still
    /// in flight for one the viewer has left does not land on the next.
    @ObservationIgnored private var generation = 0
    /// The pages read from the server since the library was chosen, as
    /// against drawn from the device's copy.
    @ObservationIgnored private var fresh: Set<Tab> = []
    @ObservationIgnored private var reading: Set<Tab> = []
    @ObservationIgnored private var started = false

    init(profile: MediaServerProfile, browser: any ServerLibraryBrowsing, defaults: UserDefaults = .standard) {
        self.profile = profile
        self.browser = browser
        self.defaults = defaults
        let sort = defaults.string(forKey: Self.key("sort", profile)).flatMap(ServerLibrarySort.init) ?? .title
        browse = ServerLibraryBrowse(sort: sort,
                                     descending: defaults.object(forKey: Self.key("descending", profile)) as? Bool
                                         ?? sort.startsDescending)
    }

    private static func key(_ name: String, _ profile: MediaServerProfile) -> String {
        "Lineup.serverLibrary." + name + "." + profile.id.uuidString
    }

    var userID: String { profile.userID }

    // MARK: - Starting

    /// The device's copy first, then the server's: its libraries, the one
    /// last shown -- or the first -- and the page in view. Coming back to a
    /// Library already shown reads the page in view again, quietly.
    func start() async {
        guard !started else {
            fresh.remove(tab)
            await loadTab(tab)
            return
        }
        started = true
        let remembered = defaults.string(forKey: Self.key("library", profile))
        if let saved = await Self.readSaved(profile: profile.id) {
            libraries = saved.libraries
            librariesPhase = .loaded
            if let shown = saved.libraries.first(where: { $0.id == remembered }) ?? saved.libraries.first {
                library = shown
                if let page = await Self.readSaved(profile: profile.id, library: shown.id), library?.id == shown.id {
                    apply(page)
                }
            }
        }
        await loadLibraries(remembered: remembered)
    }

    private func loadLibraries(remembered: String?) async {
        if libraries.isEmpty { librariesPhase = .loading }
        do {
            let found = try await browser.serverLibraries(userID: userID)
            libraries = found
            librariesPhase = .loaded
            Self.write(SavedLibraries(libraries: found), to: Self.savedURL(profile: profile.id))
            let current = library.flatMap { shown in found.first { $0.id == shown.id } }
            if let current {
                library = current
                await loadTab(tab)
            } else {
                choose(found.first { $0.id == remembered } ?? found.first)
            }
        } catch {
            if libraries.isEmpty { librariesPhase = .failed(Self.message(error)) }
            else if library != nil { await loadTab(tab) }
        }
    }

    func retry() async {
        if case .failed = librariesPhase {
            started = false
            await start()
            return
        }
        fresh.remove(tab)
        await loadTab(tab)
    }

    /// Show another of the server's libraries, from its Recommended page:
    /// what the device kept of it at once, then the server's.
    func choose(_ library: MediaItem?) {
        generation += 1
        self.library = library
        fresh = []
        reading = []
        home = ServerLibraryHome(); homePhase = .idle
        titles = []; titlesNext = nil; titlesTotal = nil; titlesPhase = .idle
        collections = []; collectionsPhase = .idle
        genres = []
        browse.genre = nil
        guard let library else { return }
        defaults.set(library.id, forKey: Self.key("library", profile))
        let chosen = generation
        Task {
            if let page = await Self.readSaved(profile: profile.id, library: library.id), chosen == generation {
                apply(page)
            }
            await loadTab(tab)
        }
    }

    // MARK: - Pages

    func loadTab(_ tab: Tab) async {
        guard library != nil, !fresh.contains(tab), !reading.contains(tab) else { return }
        reading.insert(tab)
        defer { reading.remove(tab) }
        switch tab {
        case .recommended: await loadHome()
        case .library: await loadTitles()
        case .collections: await loadCollections()
        }
        // The page in view is in: the other two are read behind it.
        if tab == self.tab {
            for other in Tab.allCases where other != tab {
                Task { await loadTab(other) }
            }
        }
    }

    private func loadHome() async {
        guard let library else { return }
        let started = generation
        if homePhase != .loaded { homePhase = .loading }
        do {
            let found = try await browser.serverLibraryHome(userID: userID, library: library)
            guard started == generation else { return }
            home = ServerLibraryHome(
                rows: found.rows.map { row in
                    var row = row
                    row.items = row.items.map(served)
                    row.collections = row.collections.map(servedCollection)
                    return row
                },
                badges: found.badges)
            badges.merge(found.badges) { _, new in new }
            homePhase = .loaded
            fresh.insert(.recommended)
            save()
        } catch {
            guard started == generation, homePhase != .loaded else { return }
            homePhase = .failed(Self.message(error))
        }
    }

    /// The grid's first page, after the library or its order changed.
    private func loadTitles() async {
        guard let library else { return }
        let started = generation
        if titlesPhase != .loaded { titlesPhase = .loading }
        if genres.isEmpty {
            Task { [browser, userID] in
                let found = (try? await browser.serverLibraryGenres(userID: userID, library: library)) ?? []
                if started == generation { genres = found }
            }
        }
        do {
            let page = try await browser.serverLibraryTitles(userID: userID, library: library, browse: browse, cursor: nil)
            guard started == generation else { return }
            titles = page.items.map(served)
            titlesNext = page.next
            titlesTotal = page.total
            badges.merge(page.badges) { _, new in new }
            titlesPhase = .loaded
            fresh.insert(.library)
            save()
        } catch {
            guard started == generation, titlesPhase != .loaded else { return }
            titlesPhase = .failed(Self.message(error))
        }
    }

    /// The grid's next page, as its last cards come into view.
    func loadMoreTitles() async {
        guard let library, titlesPhase == .loaded, !loadingMore, let cursor = titlesNext else { return }
        let started = generation
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await browser.serverLibraryTitles(userID: userID, library: library,
                                                               browse: browse, cursor: cursor),
              started == generation else { return }
        let known = Set(titles.map(\.id))
        titles += page.items.filter { !known.contains($0.id) }.map(served)
        titlesNext = page.next
        badges.merge(page.badges) { _, new in new }
    }

    var hasMoreTitles: Bool { titlesNext != nil }

    /// Change the grid's order or what it is narrowed to, and read it again.
    func setBrowse(_ change: (inout ServerLibraryBrowse) -> Void) {
        var next = browse
        change(&next)
        guard next != browse else { return }
        browse = next
        defaults.set(browse.sort.rawValue, forKey: Self.key("sort", profile))
        defaults.set(browse.descending, forKey: Self.key("descending", profile))
        generation += 1
        titles = []; titlesNext = nil; titlesTotal = nil; titlesPhase = .idle
        fresh.remove(.library)
        reading.remove(.library)
        Task { await loadTab(.library) }
    }

    /// Choose a sort; choosing the one in use turns it around.
    func sort(by sort: ServerLibrarySort) {
        setBrowse { browse in
            if browse.sort == sort, sort != .random {
                browse.descending.toggle()
            } else {
                browse.sort = sort
                browse.descending = sort.startsDescending
            }
        }
    }

    private func loadCollections() async {
        guard let library else { return }
        let started = generation
        if collectionsPhase != .loaded { collectionsPhase = .loading }
        do {
            let found = try await browser.serverLibraryCollections(userID: userID, library: library)
            guard started == generation else { return }
            collections = found.map(servedCollection)
            collectionsPhase = .loaded
            fresh.insert(.collections)
            save()
        } catch {
            guard started == generation, collectionsPhase != .loaded else { return }
            collectionsPhase = .failed(Self.message(error))
        }
    }

    /// One title at random from what the grid shows: its order and filters.
    func shuffle() async -> MediaItem? {
        guard let library else { return nil }
        var random = browse
        random.sort = .random
        let page = try? await browser.serverLibraryTitles(userID: userID, library: library, browse: random, cursor: nil)
        return (page?.items.randomElement() ?? titles.randomElement()).map(served)
    }

    /// A Recommended row in full, for its own page: up to a few pages of it.
    func rowTitles(_ row: ServerLibraryRow) async throws -> [MediaItem] {
        guard let library else { return row.items }
        var found: [MediaItem] = []
        var cursor: String?
        for _ in 0..<4 {
            let page = try await browser.serverLibraryRow(userID: userID, library: library, row: row, cursor: cursor)
            badges.merge(page.badges) { _, new in new }
            let known = Set(found.map(\.id))
            found += page.items.filter { !known.contains($0.id) }
            guard let next = page.next else { break }
            cursor = next
        }
        return (found.isEmpty ? row.items : found).map(served)
    }

    private func served(_ item: MediaItem) -> MediaItem {
        item.serverID == profile.id ? item : item.servedBy(profile.id)
    }

    private func servedCollection(_ collection: ServerLibraryCollection) -> ServerLibraryCollection {
        ServerLibraryCollection(item: served(collection.item), detail: collection.detail)
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription, !text.isEmpty { return text }
        return "The server didn't answer. Check that it's running and reachable."
    }

    // MARK: - The device's copy

    private struct SavedLibraries: Codable, Sendable { let libraries: [MediaItem] }

    /// One library as it was last shown: its rows, the grid's first page in
    /// the order it was read in, and its collections.
    private struct SavedPage: Codable, Sendable {
        var home: ServerLibraryHome?
        var titles: [MediaItem]?
        var titlesTotal: Int?
        var browse: ServerLibraryBrowse?
        var collections: [ServerLibraryCollection]?
        var badges: [String: ServerLibraryBadges] = [:]
    }

    private func apply(_ page: SavedPage) {
        badges.merge(page.badges) { old, _ in old }
        if let saved = page.home, homePhase != .loaded, !saved.rows.isEmpty {
            home = saved; homePhase = .loaded
        }
        if let saved = page.titles, page.browse == browse, titlesPhase != .loaded, !saved.isEmpty {
            titles = saved; titlesTotal = page.titlesTotal; titlesPhase = .loaded
        }
        if let saved = page.collections, collectionsPhase != .loaded, !saved.isEmpty {
            collections = saved; collectionsPhase = .loaded
        }
    }

    /// What is showing, kept for next time: the grid's first page only.
    private func save() {
        guard let library else { return }
        let first = Array(titles.prefix(ServerLibraryQuery.pageSize))
        let shown = Set(home.rows.flatMap(\.items).map(\.id) + first.map(\.id))
        let page = SavedPage(home: homePhase == .loaded ? home : nil,
                             titles: titlesPhase == .loaded ? first : nil,
                             titlesTotal: titlesTotal, browse: browse,
                             collections: collectionsPhase == .loaded ? collections : nil,
                             badges: badges.filter { shown.contains($0.key) })
        Self.write(page, to: Self.savedURL(profile: profile.id, library: library.id))
    }

    nonisolated private static func savedURL(profile: UUID, library: String? = nil) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let part = library.map { "-" + String($0.map { $0.isLetter || $0.isNumber ? $0 : "_" }) } ?? ""
        return caches.appendingPathComponent("Lineup-server-library-v1-" + profile.uuidString + part + ".json")
    }

    nonisolated private static func write<Value: Encodable & Sendable>(_ value: Value, to url: URL?) {
        guard let url else { return }
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated private static func readSaved(profile: UUID) async -> SavedLibraries? {
        await Task.detached(priority: .userInitiated) {
            guard let url = savedURL(profile: profile), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SavedLibraries.self, from: data)
        }.value
    }

    nonisolated private static func readSaved(profile: UUID, library: String) async -> SavedPage? {
        await Task.detached(priority: .userInitiated) {
            guard let url = savedURL(profile: profile, library: library), let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? JSONDecoder().decode(SavedPage.self, from: data)
        }.value
    }
}
