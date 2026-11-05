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

    /// An AIOStreams catalog of collections is a shelf of ways into lists:
    /// the hero passes over it rather than feature cropped collection art.
    func testAShelfOfCollectionsIsNeverTheHero() {
        let root = MediaItem(id: "services", name: "Streaming Services", type: "CollectionFolder",
            overview: nil, productionYear: nil, primaryImageAspectRatio: nil, childCount: 0)
        let collections = (0..<4).map { index in
            MediaItem(id: "collection-\(index)", name: "Collection \(index)", type: "BoxSet",
                overview: nil, productionYear: nil, primaryImageAspectRatio: 1.7777, childCount: nil)
        }
        let services = MediaCatalog(root: root, items: collections)
        let films = catalog("films", itemCount: 3)

        XCTAssertTrue(MediaHeroCatalogSelection.featuredItems(in: services).isEmpty)
        XCTAssertEqual(MediaHeroCatalogSelection.resolve([services, films], selectedID: nil)?.id, films.id)
        XCTAssertEqual(MediaHeroCatalogSelection.resolve([services, films], selectedID: services.id)?.id, films.id)
        XCTAssertEqual(MediaArtShape.forItems(collections), .still, "Wide collection art is drawn wide")
    }

    func testHeroUsesTheCatalogOrderAndStopsAtTen() {
        let ranked = catalog("ranked", itemCount: 14)

        let featured = MediaHeroCatalogSelection.featuredItems(in: ranked)

        XCTAssertEqual(featured.count, 10)
        XCTAssertEqual(featured.map(\.id), (0..<10).map { "ranked-\($0)" })
    }
}
