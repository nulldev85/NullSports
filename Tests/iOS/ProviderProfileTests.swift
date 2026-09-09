import XCTest
@testable import NullSportsiOS

final class ProviderProfileTests: XCTestCase {
    @MainActor
    func testLegacyFavoritesBelongOnlyToPreviouslyActiveProvider() throws {
        let suite = "ProviderProfileTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = XtreamProfile(name: "First", serverURL: "https://example.invalid", username: "one")
        let second = XtreamProfile(name: "Second", serverURL: "https://example.invalid", username: "two")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.profiles")
        defaults.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        defaults.set([42, 7], forKey: "NullSports.favoriteStreams")
        let original = SportsLibrary(profileDefaults: defaults)
        XCTAssertEqual(original.favoriteStreamOrder, [42, 7])
        XCTAssertNil(defaults.object(forKey: "NullSports.favoriteStreams"))
        defaults.set(second.id.uuidString, forKey: "NullSports.activeProfile")
        let other = SportsLibrary(profileDefaults: defaults)
        XCTAssertTrue(other.favoriteStreamOrder.isEmpty)
        let stream = XtreamStream(num: nil, name: "Channel", streamType: nil, streamID: 42,
                                  streamIcon: nil, epgChannelID: nil, categoryID: nil)
        other.addFavorite(stream)
        XCTAssertEqual(SportsLibrary(profileDefaults: defaults).favoriteStreamOrder, [42])
        defaults.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        XCTAssertEqual(SportsLibrary(profileDefaults: defaults).favoriteStreamOrder, [42, 7])
    }

    @MainActor
    func testRemovingInactiveProviderPreservesActiveProfileAndFavorites() async throws {
        let suite = "ProviderProfileTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = XtreamProfile(name: "First", serverURL: "https://example.invalid", username: "one")
        let second = XtreamProfile(name: "Second", serverURL: "https://example.invalid", username: "two")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.profiles")
        defaults.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        defaults.set([7], forKey: "NullSports.favoriteStreams.\(first.id.uuidString)")
        defaults.set([42], forKey: "NullSports.favoriteStreams.\(second.id.uuidString)")
        let library = SportsLibrary(profileDefaults: defaults)
        await library.removeProfile(second)
        XCTAssertEqual(library.activeProfile, first)
        XCTAssertEqual(library.favoriteStreamOrder, [7])
        XCTAssertEqual(library.profiles, [first])
        XCTAssertNil(defaults.object(forKey: "NullSports.favoriteStreams.\(second.id.uuidString)"))
        XCTAssertEqual(SportsLibrary(profileDefaults: defaults).profiles, [first])
        await library.removeProfile(first)
        XCTAssertFalse(library.hasProfile)
        XCTAssertTrue(library.favoriteStreamOrder.isEmpty)
        XCTAssertFalse(SportsLibrary(profileDefaults: defaults).hasProfile)
        XCTAssertFalse(library.isSwitchingProfile)
    }
}
