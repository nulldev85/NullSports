import Foundation
import Observation

/// One server's own Library while it is on screen: which of its libraries is
/// showing, and that library's Recommended rows, its titles and its
/// collections, each read the first time its tab is opened.
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

    /// How far a tab has got.
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
        didSet { if tab != oldValue { Task { await loadTab() } } }
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

    /// Which library was showing, so the request still in flight for one the
    /// viewer left does not land on the next.
    @ObservationIgnored private var generation = 0

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

    /// The libraries, then the one last shown -- or the first -- and its tab.
    func start() async {
        guard librariesPhase == .idle else { return }
        librariesPhase = .loading
        do {
            libraries = try await browser.serverLibraries(userID: userID)
            librariesPhase = .loaded
            let remembered = defaults.string(forKey: Self.key("library", profile))
            choose(libraries.first { $0.id == remembered } ?? libraries.first)
        } catch {
            librariesPhase = .failed(Self.message(error))
        }
    }

    func retry() async {
        if case .failed = librariesPhase { librariesPhase = .idle; await start(); return }
        switch tab {
        case .recommended: homePhase = .idle
        case .library: titlesPhase = .idle
        case .collections: collectionsPhase = .idle
        }
        await loadTab()
    }

    /// Show another of the server's libraries, from its Recommended page.
    func choose(_ library: MediaItem?) {
        generation += 1
        self.library = library
        if let library { defaults.set(library.id, forKey: Self.key("library", profile)) }
        home = ServerLibraryHome(); homePhase = .idle
        titles = []; titlesNext = nil; titlesTotal = nil; titlesPhase = .idle
        collections = []; collectionsPhase = .idle
        genres = []
        browse.genre = nil
        Task { await loadTab() }
    }

    func loadTab() async {
        switch tab {
        case .recommended: await loadHome()
        case .library: await loadTitles()
        case .collections: await loadCollections()
        }
    }

    private func loadHome() async {
        guard let library, homePhase == .idle else { return }
        let started = generation
        homePhase = .loading
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
        } catch {
            guard started == generation else { return }
            homePhase = .failed(Self.message(error))
        }
    }

    /// The grid's first page, after the library or its order changed.
    private func loadTitles() async {
        guard let library, titlesPhase == .idle else { return }
        let started = generation
        titlesPhase = .loading
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
        } catch {
            guard started == generation else { return }
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
        Task { await loadTitles() }
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
        guard let library, collectionsPhase == .idle else { return }
        let started = generation
        collectionsPhase = .loading
        do {
            let found = try await browser.serverLibraryCollections(userID: userID, library: library)
            guard started == generation else { return }
            collections = found.map(servedCollection)
            collectionsPhase = .loaded
        } catch {
            guard started == generation else { return }
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
}
