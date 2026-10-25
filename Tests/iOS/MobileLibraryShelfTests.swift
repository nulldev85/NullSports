import SwiftUI
import UIKit
import XCTest
import Combine
@testable import LineupiOS

@MainActor
final class MobileLibraryShelfTests: XCTestCase {
    func testLargeShelfRecyclesFixedSizeCellsAndKeepsPositionWhenMetadataChanges() throws {
        let fixture = try ShelfFixture(items: titles(500))
        defer { fixture.close() }
        let collection = fixture.collection
        collection.setContentOffset(CGPoint(x: 2_000, y: 0), animated: false)
        collection.layoutIfNeeded()
        let offset = collection.contentOffset
        let size = collection.contentSize
        let visible = collection.indexPathsForVisibleItems.sorted()
        XCTAssertFalse(visible.isEmpty)
        XCTAssertLessThan(collection.visibleCells.count, 10, "A 500-title row must recycle its cells")
        let cells = visible.compactMap { collection.cellForItem(at: $0) }
        var enriched = fixture.items
        for path in visible {
            let original = enriched[path.item]
            enriched[path.item] = MediaItem(id: original.id,
                name: "A much longer resolved title that needs both reserved lines", type: original.type,
                overview: "Updated server metadata", productionYear: 2026,
                primaryImageAspectRatio: nil, childCount: nil)
        }
        fixture.update(items: enriched)
        collection.layoutIfNeeded()
        XCTAssertEqual(collection.contentOffset, offset)
        XCTAssertEqual(collection.contentSize, size)
        for (path, cell) in zip(visible, cells) {
            XCTAssertTrue(collection.cellForItem(at: path) === cell)
            XCTAssertEqual(cell.accessibilityLabel, enriched[path.item].name)
            let attributes = try XCTUnwrap(collection.layoutAttributesForItem(at: path))
            XCTAssertEqual(attributes.size, CGSize(width: 150, height: fixture.metrics.cardHeight))
            XCTAssertEqual(attributes.frame.minY, 8, accuracy: 0.5)
        }
        let last = IndexPath(item: 499, section: 0)
        collection.scrollToItem(at: last, at: .right, animated: false)
        collection.layoutIfNeeded()
        collection.delegate?.collectionView?(collection, didSelectItemAt: last)
        XCTAssertEqual(fixture.selected.last, fixture.items[499].libraryKey)
        XCTAssertLessThan(collection.visibleCells.count, 10)
    }

    func testInsertionsAndRecreationKeepTheSamePosterAtTheSamePosition() throws {
        let position = MobileLibraryShelfPosition()
        let fixture = try ShelfFixture(items: titles(50), position: position)
        defer { fixture.close() }
        fixture.collection.setContentOffset(CGPoint(x: 1_003, y: 0), animated: false)
        fixture.collection.layoutIfNeeded()
        let key = try XCTUnwrap(position.key)
        let distance = position.distance
        fixture.update(items: [title("inserted")] + fixture.items)
        fixture.collection.layoutIfNeeded()
        let index = try XCTUnwrap(fixture.items.firstIndex { $0.libraryKey == key })
        let attributes = try XCTUnwrap(fixture.collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0)))
        XCTAssertEqual(fixture.collection.contentOffset.x - attributes.frame.minX, distance, accuracy: 0.5)
        let expectedOffset = fixture.collection.contentOffset.x

        // The vertical lazy stack can dispose of the UIView while retaining
        // the row's SwiftUI state. Returning must not reset the row to item 0.
        let restored = try ShelfFixture(items: fixture.items, position: position)
        defer { restored.close() }
        XCTAssertEqual(restored.collection.contentOffset.x, expectedOffset, accuracy: 0.5)
        restored.update(items: Array(restored.items.prefix(2)))
        restored.collection.layoutIfNeeded()
        XCTAssertEqual(restored.collection.contentOffset.x, 0, accuracy: 0.5)
    }

    func testStillRowsAndLargerTextHaveStableGeometryAndHoldTheCurrentItem() throws {
        let episodes = titles(30, type: "Episode")
        let fixture = try ShelfFixture(items: episodes, shape: .still,
            metrics: MobileLibraryShelfMetrics(width: 232, ratio: 16 / 9, titleHeight: 68, metadataHeight: 26))
        defer { fixture.close() }
        let path = IndexPath(item: 0, section: 0)
        let cell = try XCTUnwrap(fixture.collection.cellForItem(at: path))
        XCTAssertEqual(try XCTUnwrap(fixture.collection.layoutAttributesForItem(at: path)).size.height,
                       fixture.metrics.cardHeight, accuracy: 0.5)
        let more = try XCTUnwrap(cell.accessibilityCustomActions?.first)
        XCTAssertTrue(more.actionHandler?(more) == true)
        XCTAssertEqual(fixture.holdMenu.request?.title, episodes[0].name)
        XCTAssertTrue(fixture.holdMenu.request?.items.contains { $0.title == "Mark Watched" } == true)
        fixture.update(items: Array(episodes.reversed()))
        fixture.collection.delegate?.collectionView?(fixture.collection, didSelectItemAt: path)
        XCTAssertEqual(fixture.selected.last, episodes.last?.libraryKey)
    }

    func testRetinaSizingUsesPosterHeightForDecodeAndWidthForTheServer() {
        let poster = MobileLibraryArtworkSize(width: 210, ratio: 2 / 3, scale: 3)
        XCTAssertEqual(poster.width, 630)
        XCTAssertEqual(poster.longestEdge, 945)
        let still = MobileLibraryArtworkSize(width: 300, ratio: 16 / 9, scale: 3)
        XCTAssertEqual(still.width, 900)
        XCTAssertEqual(still.longestEdge, 900)
    }

    func testNativePosterMenuOpensCollectionsForTheCurrentRecycledTitle() throws {
        let fixture = try ShelfFixture(items: titles(30))
        defer { fixture.close() }
        let cell = try XCTUnwrap(fixture.collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        let more = try XCTUnwrap(cell.accessibilityCustomActions?.first)
        XCTAssertTrue(more.actionHandler?(more) == true)
        let choice = try XCTUnwrap(fixture.holdMenu.request?.items.first { $0.title == "Collections" })
        choice.action()
        XCTAssertEqual(fixture.media.collectionSelectionItem?.libraryKey, fixture.items[0].libraryKey)
        fixture.update(items: Array(fixture.items.reversed()))
        let path = try XCTUnwrap(fixture.collection.indexPathsForVisibleItems.first)
        let current = try XCTUnwrap(fixture.collection.cellForItem(at: path))
        let currentMore = try XCTUnwrap(current.accessibilityCustomActions?.first)
        XCTAssertTrue(currentMore.actionHandler?(currentMore) == true)
        let changed = try XCTUnwrap(fixture.holdMenu.request?.items.first { $0.title == "Collections" })
        changed.action()
        XCTAssertEqual(fixture.media.collectionSelectionItem?.libraryKey, fixture.items[path.item].libraryKey)
    }

    func testLateImageCannotReplaceANewerPosterAndSizeChangesAreSeparateRequests() async throws {
        let model = MobileLibraryArtwork()
        let first = MobileLibraryArtworkRequest(url: URL(string: "https://art.invalid/a.jpg"), pixels: 300)
        let second = MobileLibraryArtworkRequest(url: URL(string: "https://art.invalid/b.jpg"), pixels: 600)
        let started = expectation(description: "first image request is actually awaiting its response")
        var pending: CheckedContinuation<UIImage?, Never>?
        let oldTask = Task {
            await model.load(first, cached: { _, _ in nil }, fetch: { _, _ in
                await withCheckedContinuation { pending = $0; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 5)
        let newer = UIImage(systemName: "star.fill")!
        await model.load(second, cached: { _, _ in nil }, fetch: { _, _ in newer })
        pending?.resume(returning: UIImage(systemName: "film"))
        await oldTask.value
        XCTAssertTrue(model.image(for: second) === newer)
        XCTAssertNil(model.image(for: first))
        let larger = MobileLibraryArtworkRequest(url: second.url, pixels: 900)
        XCTAssertNil(model.image(for: larger))
        var requestedPixels = 0
        await model.load(larger, cached: { _, _ in nil }, fetch: { _, pixels in
            requestedPixels = pixels
            return newer
        })
        XCTAssertEqual(requestedPixels, 900)
        XCTAssertTrue(model.image(for: larger) === newer)
        XCTAssertNil(model.image(for: second))
        await model.load(MobileLibraryArtworkRequest(url: nil, pixels: 600))
        XCTAssertNil(model.image(for: second))
    }

    func testCancelledImageSubscriberDoesNotPublishAfterItsSharedDownloadCompletes() async {
        let model = MobileLibraryArtwork()
        let request = MobileLibraryArtworkRequest(url: URL(string: "https://art.invalid/c.jpg"), pixels: 300)
        let started = expectation(description: "image subscriber started")
        var pending: CheckedContinuation<UIImage?, Never>?
        let task = Task {
            await model.load(request, cached: { _, _ in nil }, fetch: { _, _ in
                await withCheckedContinuation { pending = $0; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        pending?.resume(returning: UIImage(systemName: "film"))
        await task.value
        XCTAssertNil(model.image(for: request))
    }

    func testTitleLogoPublishesFastTMDBWhileFanartIsPendingThenUsesPreferredArtwork() async {
        let model = MobileTitleArtwork()
        let fallback = UIImage(systemName: "star")!, preferred = UIImage(systemName: "film")!
        let fastURL = URL(string: "https://image.invalid/tmdb.png")!
        let preferredURL = URL(string: "https://image.invalid/fanart.png")!
        let started = expectation(description: "Fanart metadata request pending")
        let published = expectation(description: "TMDB image published without waiting for Fanart")
        var reported = false
        let observer = model.objectWillChange.sink {
            Task { @MainActor in
                if !reported, model.image(for: "title") === fallback { reported = true; published.fulfill() }
            }
        }
        defer { observer.cancel() }
        var reply: CheckedContinuation<URL?, Never>?
        let load = Task {
            await model.load(key: "title", pixels: 600, server: nil,
                fanart: { await withCheckedContinuation { reply = $0; started.fulfill() } },
                tmdb: { fastURL }, fetch: { url, _ in url == fastURL ? fallback : preferred })
        }
        await fulfillment(of: [started, published], timeout: 5)
        XCTAssertTrue(model.image(for: "title") === fallback)
        reply?.resume(returning: preferredURL)
        await load.value
        XCTAssertTrue(model.image(for: "title") === preferred)
    }

    func testLateTitleLogoCannotOverwriteANewerTitleOrPixelRequest() async {
        let model = MobileTitleArtwork()
        let oldImage = UIImage(systemName: "film")!, newImage = UIImage(systemName: "star.fill")!
        let url = URL(string: "https://image.invalid/\(UUID().uuidString).png")!
        let started = expectation(description: "old title request started")
        var reply: CheckedContinuation<URL?, Never>?
        let old = Task {
            await model.load(key: "old|300", pixels: 300, server: nil,
                fanart: { await withCheckedContinuation { reply = $0; started.fulfill() } },
                tmdb: { nil }, fetch: { _, _ in oldImage })
        }
        await fulfillment(of: [started], timeout: 5)
        await model.load(key: "new|600", pixels: 600, server: nil,
            fanart: { nil }, tmdb: { url }, fetch: { _, pixels in
                XCTAssertEqual(pixels, 600); return newImage
            })
        reply?.resume(returning: url)
        await old.value
        XCTAssertTrue(model.image(for: "new|600") === newImage)
        XCTAssertNil(model.image(for: "old|300"))
    }

    func testSimilarCatalogShelfHoldFindsSourcesWithoutWritingSyntheticWatchState() throws {
        let items = titles(2)
        let fixture = try ShelfFixture(items: items, discoversSources: true)
        defer { fixture.close() }
        let cell = try XCTUnwrap(fixture.collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        let more = try XCTUnwrap(cell.accessibilityCustomActions?.first)
        XCTAssertTrue(more.actionHandler?(more) == true)
        let choices = try XCTUnwrap(fixture.holdMenu.request?.items)
        XCTAssertEqual(choices.map(\.title), ["Find in My Sources"])
        choices[0].action()
        XCTAssertEqual(fixture.selected, [items[0].libraryKey])
        XCTAssertTrue(fixture.media.localPlayback.isEmpty)
        XCTAssertTrue(fixture.media.favoriteMedia.isEmpty)
    }

    private func titles(_ count: Int, type: String = "Movie") -> [MediaItem] {
        (0..<count).map { title("title-\($0)", type: type) }
    }

    private func title(_ id: String, type: String = "Movie") -> MediaItem {
        MediaItem(id: id, name: id, type: type, overview: nil, productionYear: nil,
                  primaryImageAspectRatio: nil, childCount: nil)
    }
}

@MainActor
private final class ShelfFixture {
    let collection: UICollectionView
    let coordinator: MobileLibraryShelfView.Coordinator
    let position: MobileLibraryShelfPosition
    let media: MediaLibrary
    let holdMenu = MobileHoldMenu()
    let metrics: MobileLibraryShelfMetrics
    let shape: MediaArtShape
    let discoversSources: Bool
    private(set) var items: [MediaItem]
    var selected: [String] { selections.keys }
    private let window: UIWindow
    private weak var previous: UIWindow?
    private let defaults: UserDefaults
    private let suite = "MobileLibraryShelfTests.\(UUID())"
    private let selections: ShelfSelections

    init(items: [MediaItem], position: MobileLibraryShelfPosition = MobileLibraryShelfPosition(),
         shape: MediaArtShape = .poster,
         metrics: MobileLibraryShelfMetrics = .init(width: 150, ratio: 2 / 3, titleHeight: 40, metadataHeight: 16),
         discoversSources: Bool = false) throws {
        self.items = items
        self.position = position
        self.shape = shape
        self.metrics = metrics
        self.discoversSources = discoversSources
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        media = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""))
        selections = ShelfSelections()
        let selectionStore = selections
        let shelf = MobileLibraryShelfView(items: items, shape: shape, metrics: metrics, media: media,
            position: position, holdMenu: holdMenu, discoversSources: discoversSources,
            onSelect: { selectionStore.keys.append($0.libraryKey) })
        coordinator = MobileLibraryShelfView.Coordinator(shelf)
        collection = coordinator.makeCollectionView()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        collection.frame = CGRect(x: 0, y: 100, width: 390, height: metrics.height)
        parent.view.addSubview(collection)
        collection.setNeedsLayout()
        collection.layoutIfNeeded()
        coordinator.didLayout()
    }

    func update(items: [MediaItem]) {
        self.items = items
        coordinator.update(MobileLibraryShelfView(items: items, shape: shape, metrics: metrics, media: media,
            position: position, holdMenu: holdMenu, discoversSources: discoversSources,
            onSelect: { [selections] in selections.keys.append($0.libraryKey) }))
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
        defaults.removePersistentDomain(forName: suite)
    }

}

@MainActor
private final class ShelfSelections {
    var keys: [String] = []
}
