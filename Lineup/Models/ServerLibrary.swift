import Foundation

// A media server's own Library, the way its own app lays it out: one of its
// libraries at a time -- Movies, Shows -- as the rows the server recommends,
// every title in a grid, and the server's collections. Each server answers
// from its own catalog, so Silo looks like Silo and Jellyfin like Jellyfin.

/// How a server library's grid is ordered.
enum ServerLibrarySort: String, CaseIterable, Sendable {
    case title, added, released, rating, random

    var label: String {
        switch self {
        case .title: "Title"
        case .added: "Date Added"
        case .released: "Release Date"
        case .rating: "Rating"
        case .random: "Random"
        }
    }

    /// Which way a sort runs when it is first chosen: titles from A, the
    /// rest newest or best first.
    var startsDescending: Bool { self != .title }

    /// What the sort button says after the sort's name: "A–Z", "Newest".
    func direction(descending: Bool) -> String? {
        switch self {
        case .title: descending ? "Z–A" : "A–Z"
        case .added, .released: descending ? "Newest" : "Oldest"
        case .rating: descending ? "Highest" : "Lowest"
        case .random: nil
        }
    }
}

/// What a server library's grid shows: its order, and what it is narrowed to.
struct ServerLibraryBrowse: Hashable, Sendable {
    var sort: ServerLibrarySort = .title
    var descending = false
    var genre: String?
    var kind: CatalogMediaFilter = .all
    var unwatchedOnly = false

    var isFiltered: Bool { genre != nil || kind != .all || unwatchedOnly }
}

/// What a server writes on a poster about the file it holds: "1080P" and
/// "EAC3" across the top, "WEBRIP" or "REMUX" at the foot. Only servers
/// that send it on a listing have any.
struct ServerLibraryBadges: Hashable, Sendable {
    var top: [String] = []
    var bottom: String?

    var isEmpty: Bool { top.isEmpty && bottom == nil }

    init(top: [String] = [], bottom: String? = nil) {
        self.top = top.map(Self.tidy).filter { !$0.isEmpty }
        self.bottom = bottom.map(Self.tidy).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

/// One of the server's collections, with what its card says under its
/// name: where it came from ("Tmdb", "Mdblist"), when the server says.
struct ServerLibraryCollection: Identifiable, Hashable, Sendable {
    let item: MediaItem
    var detail: String?
    var id: String { item.libraryKey }
}

/// One row of a server library's Recommended page.
struct ServerLibraryRow: Identifiable, Hashable, Sendable {
    /// Where the rest of the row is read from, for its full list.
    enum Source: Hashable, Sendable {
        /// A row the server builds itself: Silo's sections.
        case section(String)
        /// A row that is a sorted, narrowed view of the library.
        case browse(ServerLibraryBrowse)
        /// A row with no more than it shows.
        case fixed
    }

    let id: String
    let title: String
    var items: [MediaItem] = []
    /// A row of collections rather than titles.
    var collections: [ServerLibraryCollection] = []
    var source: Source = .fixed
    /// How many it holds in all, when the server says.
    var total: Int?
}

/// A server library's Recommended page.
struct ServerLibraryHome: Sendable {
    var rows: [ServerLibraryRow] = []
    var badges: [String: ServerLibraryBadges] = [:]
}

/// One page of a grid, and where the next one starts.
struct ServerLibraryPage: Sendable {
    var items: [MediaItem] = []
    var badges: [String: ServerLibraryBadges] = [:]
    var next: String?
    var total: Int?
}

/// A media server that can be shown the way its own app shows it. Kept apart
/// from `MediaServerClient`, which every server and every stand-in for one
/// answers: this is only for the servers that offer it.
protocol ServerLibraryBrowsing: Sendable {
    /// The libraries to choose between, in the server's order.
    func serverLibraries(userID: String) async throws -> [MediaItem]
    func serverLibraryHome(userID: String, library: MediaItem) async throws -> ServerLibraryHome
    func serverLibraryRow(userID: String, library: MediaItem, row: ServerLibraryRow,
                          cursor: String?) async throws -> ServerLibraryPage
    func serverLibraryTitles(userID: String, library: MediaItem, browse: ServerLibraryBrowse,
                             cursor: String?) async throws -> ServerLibraryPage
    func serverLibraryCollections(userID: String, library: MediaItem) async throws -> [ServerLibraryCollection]
    func serverLibraryGenres(userID: String, library: MediaItem) async throws -> [String]
}

extension ServerLibraryBrowsing {
    /// A row's full list: a sorted view of the library is read as the grid
    /// is, and a row with nothing more is what it shows.
    func serverLibraryRow(userID: String, library: MediaItem, row: ServerLibraryRow,
                          cursor: String?) async throws -> ServerLibraryPage {
        switch row.source {
        case .browse(let browse):
            return try await serverLibraryTitles(userID: userID, library: library, browse: browse, cursor: cursor)
        case .section, .fixed:
            return cursor == nil ? ServerLibraryPage(items: row.items, total: row.items.count) : ServerLibraryPage()
        }
    }
}

enum ServerLibraryQuery {
    /// Titles in a page of the grid.
    static let pageSize = 60
    /// Titles in a row of the Recommended page.
    static let rowSize = 20
    /// How far the grid reads before it stops offering more: a library of
    /// tens of thousands is searched or filtered, not scrolled to its end.
    static let maxTitles = 5_000

    /// A cursor that is a count of titles already read, for the servers
    /// that page by offset.
    static func offset(_ cursor: String?) -> Int { cursor.flatMap(Int.init) ?? 0 }

    /// The cursor after a page read by offset, or nil at the end.
    static func next(after offset: Int, read: Int, total: Int?) -> String? {
        let reached = offset + read
        guard read > 0, reached < maxTitles else { return nil }
        if let total { return reached < total ? String(reached) : nil }
        return read < pageSize ? nil : String(reached)
    }
}
