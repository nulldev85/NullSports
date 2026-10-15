import XCTest
@testable import Lineup

@MainActor
final class LibraryMenuTests: XCTestCase {
    func testUnstartedMovieOffersWatchedAndFavorites() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = item(type: "Movie")
        XCTAssertEqual(library.tvCardChoices(for: movie).map(\.title), ["Mark Watched", "Add to Favorites"])
        library.setLocallyPlayed(true, for: movie)
        library.setLocalFavorite(true, for: movie)
        XCTAssertEqual(library.tvCardChoices(for: movie).map(\.title), ["Mark Unwatched", "Remove from Favorites"])
    }

    func testEpisodeMenuReflectsLocalWatchedAndUnwatchedMarks() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episode = item(type: "Episode")
        library.setLocallyPlayed(true, for: episode)
        XCTAssertEqual(library.tvEpisodeChoices(for: episode).first?.title, "Mark Unwatched")
        library.setLocallyPlayed(false, for: episode)
        XCTAssertEqual(library.tvEpisodeChoices(for: episode).first?.title, "Mark Watched")
    }

    func testResumeMovieStillOffersTrackingActions() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = item(type: "Movie")
        library.trackPlayback(of: movie, position: 300, duration: 3_600)
        XCTAssertEqual(library.tvCardChoices(for: movie).map(\.title),
                       ["Remove from Continue Watching", "Mark Watched", "Add to Favorites"])
    }

    private func item(type: String) -> MediaItem {
        MediaItem(id: type, name: "Title", type: type, overview: nil,
                  productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
    }

    private func makeLibrary() throws -> (MediaLibrary, UserDefaults, String) {
        let suite = "LibraryMenuTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profile = MediaServerProfile(name: "Server", serverURL: "http://server",
                                        username: "viewer", userID: "user")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        defaults.set(profile.id.uuidString, forKey: "NullSports.activeMediaServer")
        return (MediaLibrary(defaults: defaults), defaults, suite)
    }
}
