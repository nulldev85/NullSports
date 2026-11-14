import XCTest
import SwiftUI
import UIKit
@testable import LineupiOS

final class MediaHeroTests: XCTestCase {
    @MainActor
    func testHeroArtworkReachesBothEdgesWhileForegroundRespectsSideInsets() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let artwork = UIView()
        let foreground = UIView()
        let host = UIHostingController(rootView: MobileLibraryHeroViewport(extendsArtwork: true) { margins in
            ScrollView {
                LazyVStack {
                    ZStack {
                        HeroLayoutMarker(view: artwork).mobileHeroArtworkMargins(margins)
                        HeroLayoutMarker(view: foreground)
                    }
                    .frame(height: 140)
                }
                .padding(margins)
            }
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }

        for (left, right) in [(0, 52), (38, 0), (0, 0)] {
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: CGFloat(left), bottom: 0, right: CGFloat(right))
            let deadline = ContinuousClock.now + .seconds(3)
            var art = CGRect.zero
            var copy = CGRect.zero
            var safe = CGRect.zero
            repeat {
                window.layoutIfNeeded()
                safe = host.view.convert(host.view.safeAreaLayoutGuide.layoutFrame, to: window)
                art = artwork.convert(artwork.bounds, to: window)
                copy = foreground.convert(foreground.bounds, to: window)
                if artwork.window === window && foreground.window === window &&
                    abs(copy.minX - safe.minX) <= 1 && abs(copy.maxX - safe.maxX) <= 1 &&
                    abs(art.minX - window.bounds.minX) <= 1 && abs(art.maxX - window.bounds.maxX) <= 1 { break }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            XCTAssertEqual(art.minX, window.bounds.minX, accuracy: 1)
            XCTAssertEqual(art.maxX, window.bounds.maxX, accuracy: 1)
            XCTAssertEqual(copy.minX, safe.minX, accuracy: 1)
            XCTAssertEqual(copy.maxX, safe.maxX, accuracy: 1)
        }
    }

    func testContinueWatchingIdentifiesShowWhenEveryCardIsAnEpisode() {
        let episode = MediaItem(id: "e", name: "Pilot", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: 1.78, childCount: nil, indexNumber: 1,
            parentIndexNumber: 1, seriesName: "The Wire", seriesID: "s")
        let shape = MediaArtShape.forItems([episode], shelfID: LibraryShelfOrder.continueWatching)
        XCTAssertEqual(shape, .poster)
        XCTAssertEqual(shape.showTitle(for: episode), "The Wire")
        XCTAssertEqual(episode.episodeCode, "S01E01")
        XCTAssertEqual(MediaArtShape.forItems([episode]), .still)
    }
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

    func testSelectedSourcesTakeTurnsSkippingFoldersAndRepeatedTitles() {
        let a = catalog("a", itemCount: 6), b = catalog("b", itemCount: 6)
        // The two lists use different item IDs for the same six titles.
        let second = MediaCatalog(root: b.root, items: [b.root, b.items[0], b.items[4], b.items[5]])
        let mix = MediaHeroCatalogSelection.mix([a, second, catalog("empty", itemCount: 0)])
        XCTAssertEqual(mix.map(\.id), ["a-0", "b-4", "a-1", "b-5", "a-2", "a-3"])
    }

    func testShuffleIsStableBetweenRedrawsAndSamplesBeyondTheFirstTen() {
        let shelf = catalog("many", itemCount: 80)
        let samples = (0..<8).map { MediaHeroCatalogSelection.mix([shelf], seed: $0).map(\.id) }
        XCTAssertEqual(samples[0], MediaHeroCatalogSelection.mix([shelf], seed: 0).map(\.id))
        XCTAssertTrue(samples.allSatisfy { $0.count == 10 && Set($0).count == 10 })
        XCTAssertGreaterThan(Set(samples.flatMap { $0 }).count, 10)
    }

    @MainActor
    func testMixPreferencesSurviveRelaunchAndKeepSingleSourceChoice() throws {
        let suite = "HeroSourcesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(["library": "previous"]), forKey: "Lineup.mediaHeroCatalog.v1")
        let library = MediaLibrary(defaults: defaults)
        XCTAssertEqual(library.heroPreferences.mode, .single)
        library.setHeroMode(.selected)
        for id in 1...6 { library.toggleHeroSource(LibraryHeroSource(mdbListID: id, name: "List \(id)")) }
        XCTAssertEqual(library.heroPreferences.sources.compactMap(\.mdbListID), [1, 2, 3, 4, 5])
        library.toggleHeroSource(LibraryHeroSource(mdbListID: 2, name: "List 2"))
        library.toggleHeroSource(LibraryHeroSource(mdbListID: 6, name: "List 6"))
        library.setHeroMode(.shuffle)
        let reopened = MediaLibrary(defaults: defaults)
        XCTAssertEqual(reopened.heroPreferences.mode, .shuffle)
        reopened.setHeroMode(.selected)
        XCTAssertEqual(reopened.heroPreferences.sources.compactMap(\.mdbListID), [1, 3, 4, 5, 6])
        reopened.setHeroMode(.single)
        XCTAssertEqual(reopened.selectedHeroCatalogID, "previous")
    }
}

private struct HeroLayoutMarker: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ view: UIView, context: Context) {}
}
