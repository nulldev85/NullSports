import XCTest
@testable import LineupiOS

/// The Library's rows in the viewer's order, as rows come and go.
final class LibraryShelfOrderTests: XCTestCase {
    @MainActor
    func testCollectionsIsAnEditableRowAndItsPositionPersistsAndResets() throws {
        let domain = "CollectionsShelfOrderTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let profile = MediaServerProfile(name: "Test", serverURL: "https://server.invalid",
                                         username: "test", userID: "user")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        let media = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""))
        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
                              productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, serverID: profile.id)
        media.setLocalFavorite(true, for: movie)
        let original = media.libraryRows.map(\.id)
        XCTAssertEqual(original.first, LibraryShelfOrder.collections)
        XCTAssertTrue(original.contains(LibraryShelfOrder.favorites))
        let index = try XCTUnwrap(original.firstIndex(of: LibraryShelfOrder.collections))
        let moved = LibraryShelfOrder.move(original, from: index, by: original.count - 1)
        media.saveShelfOrder(moved)
        XCTAssertEqual(media.libraryRows.map(\.id), moved)
        let restored = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""))
        XCTAssertEqual(restored.libraryRows.map(\.id), moved)
        restored.renameShelf(id: LibraryShelfOrder.collections, to: "My Collections")
        XCTAssertEqual(restored.libraryRows.first { $0.id == LibraryShelfOrder.collections }?.title, "My Collections")
        restored.resetShelfOrder()
        XCTAssertEqual(restored.libraryRows.map(\.id), original)
    }

    func testNoSavedOrderKeepsTheRowsAsTheyCome() {
        XCTAssertEqual(LibraryShelfOrder.arrange(["a", "b", "c"], by: []), ["a", "b", "c"])
    }

    func testSavedOrderIsFollowed() {
        XCTAssertEqual(LibraryShelfOrder.arrange(["a", "b", "c"], by: ["c", "a", "b"]), ["c", "a", "b"])
    }

    func testANewShelfArrivesAfterTheRowItFollowed() {
        // "d" was added since the order was saved: it came after "c".
        XCTAssertEqual(LibraryShelfOrder.arrange(["a", "b", "c", "d"], by: ["c", "a", "b"]),
                       ["c", "d", "a", "b"])
        // A row with nothing before it goes first.
        XCTAssertEqual(LibraryShelfOrder.arrange(["new", "a", "b"], by: ["b", "a"]), ["new", "b", "a"])
    }

    func testRowsNoLongerThereAreSkipped() {
        XCTAssertEqual(LibraryShelfOrder.arrange(["a", "c"], by: ["c", "gone", "a"]), ["c", "a"])
    }

    func testSavingKeepsAHiddenRowsPlace() {
        // Continue Watching is empty, so not on screen, while the rest move.
        let saved = ["continue-watching", "a", "b", "c"]
        XCTAssertEqual(LibraryShelfOrder.saving(["c", "a", "b"], over: saved),
                       ["continue-watching", "c", "a", "b"])
        let later = ["a", "continue-watching", "b"]
        XCTAssertEqual(LibraryShelfOrder.saving(["b", "a"], over: later),
                       ["b", "a", "continue-watching"])
    }

    func testSavingAddsRowsNeverSavedBefore() {
        XCTAssertEqual(LibraryShelfOrder.saving(["b", "a"], over: []), ["b", "a"])
    }

    func testMoveStaysInBounds() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(LibraryShelfOrder.move(ids, from: 2, by: -1), ["a", "c", "b"])
        XCTAssertEqual(LibraryShelfOrder.move(ids, from: 0, by: 1), ["b", "a", "c"])
        XCTAssertEqual(LibraryShelfOrder.move(ids, from: 0, by: -1), ids)
        XCTAssertEqual(LibraryShelfOrder.move(ids, from: 2, by: 1), ids)
        XCTAssertEqual(LibraryShelfOrder.move(ids, from: 5, by: 1), ids)
    }

    func testAHeroListHasTheIDItWouldHaveAsAShelf() {
        let server = UUID()
        let root = MediaItem(id: "lib", name: "Movies", type: "CollectionFolder", overview: nil,
                             productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, serverID: server)
        XCTAssertEqual(LibraryHeroSource(root: root, name: "Movies").id, MediaCatalog.id(for: root))
        XCTAssertEqual(LibraryHeroSource(mdbListID: 42, name: "Top").id, "mdblist:42")
        let source = LibraryHeroSource(root: root, name: "Movies")
        let decoded = try? JSONDecoder().decode(LibraryHeroSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded, source)
    }

    func testTheOldAutomaticServerShelvesAreRecognised() {
        func root(_ id: String, _ name: String) -> MediaItem {
            MediaItem(id: id, name: name, type: "CollectionFolder", overview: nil,
                      productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        }
        let roots = [root("m", "Movies"), root("tm", "Trending Movies"), root("tv", "Trending TV")]
        XCTAssertEqual(MediaLibrary.formerAutomaticShelfIDs(in: roots), ["tm", "tv"])
        XCTAssertEqual(MediaLibrary.formerAutomaticShelfIDs(in: [root("a", "Movies"), root("b", "Shows"), root("c", "Kids")]),
                       ["a", "b"])
    }

    func testRowsOfAnyKindAreArrangedByID() {
        struct Row { let id: String; let title: String }
        let rows = [Row(id: "a", title: "A"), Row(id: "b", title: "B")]
        XCTAssertEqual(LibraryShelfOrder.arranged(rows, id: \.id, by: ["b", "a"]).map(\.title), ["B", "A"])
    }
}
