import XCTest
@testable import LineupiOS

final class FavoritesOrderTests: XCTestCase {
    @MainActor
    private func makeLibrary(favorites: [Int]) throws -> (SportsLibrary, UserDefaults, String) {
        let suite = "FavoritesOrderTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let profile = XtreamProfile(name: "Provider", serverURL: "https://example.invalid", username: "one")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.profiles")
        defaults.set(profile.id.uuidString, forKey: "NullSports.activeProfile")
        defaults.set(favorites, forKey: "NullSports.favoriteStreams.\(profile.id.uuidString)")
        return (SportsLibrary(profileDefaults: defaults), defaults, suite)
    }

    private func streams(_ ids: [Int]) -> [XtreamStream] {
        ids.map {
            XtreamStream(num: nil, name: "Channel \($0)", streamType: nil, streamID: $0,
                         streamIcon: nil, epgChannelID: nil, categoryID: nil)
        }
    }

    @MainActor
    func testDraggingAFavoriteMatchesSwiftUIMoveSemantics() throws {
        let (library, defaults, suite) = try makeLibrary(favorites: [1, 2, 3, 4])
        defer { defaults.removePersistentDomain(forName: suite) }
        let listed = streams([1, 2, 3, 4])

        // Dragging the first row down between 2 and 3 leaves it after 2.
        library.moveFavorites(listed, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(library.favoriteStreamOrder, [2, 1, 3, 4])
    }

    @MainActor
    func testDraggingAFavoriteUpwardAndToTheEnd() throws {
        let (library, defaults, suite) = try makeLibrary(favorites: [1, 2, 3, 4])
        defer { defaults.removePersistentDomain(forName: suite) }

        library.moveFavorites(streams([1, 2, 3, 4]), fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(library.favoriteStreamOrder, [3, 1, 2, 4])

        library.moveFavorites(streams([3, 1, 2, 4]), fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(library.favoriteStreamOrder, [1, 2, 4, 3])
    }

    @MainActor
    func testMovingSeveralFavoritesAtOnce() throws {
        let (library, defaults, suite) = try makeLibrary(favorites: [1, 2, 3, 4, 5])
        defer { defaults.removePersistentDomain(forName: suite) }

        library.moveFavorites(streams([1, 2, 3, 4, 5]), fromOffsets: IndexSet([0, 2]), toOffset: 5)
        XCTAssertEqual(library.favoriteStreamOrder, [2, 4, 5, 1, 3])
    }

    @MainActor
    func testFavoritesMissingFromTheLineupKeepTheirSlots() throws {
        // 99 is a favorite the provider no longer carries, so the guide never lists it.
        let (library, defaults, suite) = try makeLibrary(favorites: [1, 99, 2, 3])
        defer { defaults.removePersistentDomain(forName: suite) }

        library.moveFavorites(streams([1, 2, 3]), fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(library.favoriteStreamOrder, [2, 99, 1, 3])
    }

    @MainActor
    func testReorderSurvivesRelaunch() throws {
        let (library, defaults, suite) = try makeLibrary(favorites: [1, 2, 3])
        defer { defaults.removePersistentDomain(forName: suite) }

        library.moveFavorites(streams([1, 2, 3]), fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(SportsLibrary(profileDefaults: defaults).favoriteStreamOrder, [3, 1, 2])
    }
}
