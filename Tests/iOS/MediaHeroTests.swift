import XCTest
@testable import LineupiOS

final class MediaHeroTests: XCTestCase {
    private func catalog(_ id: String, itemCount: Int) -> MediaCatalog {
        let root = MediaItem(id: id, name: id.capitalized, type: "Folder",
            overview: nil, productionYear: nil, primaryImageAspectRatio: nil,
            childCount: itemCount)
        let items = (0..<itemCount).map { index in
            MediaItem(id: "\(id)-\(index)", name: "Title \(index)", type: "Movie",
                overview: nil, productionYear: nil, primaryImageAspectRatio: nil,
                childCount: nil)
        }
        return MediaCatalog(root: root, items: items)
    }

    func testSavedPopulatedCatalogWins() {
        let first = catalog("first", itemCount: 1)
        let chosen = catalog("chosen", itemCount: 2)

        XCTAssertEqual(MediaHeroCatalogSelection.resolve([first, chosen], selectedID: chosen.id)?.id,
                       chosen.id)
    }

    func testMissingOrEmptyChoiceFallsBackToFirstPopulatedShelf() {
        let empty = catalog("empty", itemCount: 0)
        let populated = catalog("populated", itemCount: 1)

        XCTAssertEqual(MediaHeroCatalogSelection.resolve([empty, populated], selectedID: empty.id)?.id,
                       populated.id)
        XCTAssertEqual(MediaHeroCatalogSelection.resolve([empty, populated], selectedID: "removed")?.id,
                       populated.id)
    }

    func testHeroUsesTheCatalogOrderAndStopsAtTen() {
        let ranked = catalog("ranked", itemCount: 14)

        let featured = MediaHeroCatalogSelection.featuredItems(in: ranked)

        XCTAssertEqual(featured.count, 10)
        XCTAssertEqual(featured.map(\.id), (0..<10).map { "ranked-\($0)" })
    }
}
