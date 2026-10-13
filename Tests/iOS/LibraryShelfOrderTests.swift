import XCTest
@testable import LineupiOS

/// The Library's rows in the viewer's order, as rows come and go.
final class LibraryShelfOrderTests: XCTestCase {
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

    func testRowsOfAnyKindAreArrangedByID() {
        struct Row { let id: String; let title: String }
        let rows = [Row(id: "a", title: "A"), Row(id: "b", title: "B")]
        XCTAssertEqual(LibraryShelfOrder.arranged(rows, id: \.id, by: ["b", "a"]).map(\.title), ["B", "A"])
    }
}
