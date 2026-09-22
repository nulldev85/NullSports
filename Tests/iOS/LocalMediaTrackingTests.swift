import XCTest
@testable import LineupiOS

@MainActor
final class LocalMediaTrackingTests: XCTestCase {
    private func record(position: TimeInterval, duration: TimeInterval,
                        completed: Bool = false) -> LocalMediaPlayback {
        LocalMediaPlayback(
            profileID: UUID(),
            item: MediaItem(id: "movie-1", name: "Movie", type: "Movie",
                overview: nil, productionYear: nil, primaryImageAspectRatio: nil,
                childCount: nil),
            position: position,
            duration: duration,
            updatedAt: Date(timeIntervalSince1970: 1),
            completed: completed
        )
    }

    func testResumeRequiresMeaningfulProgressAndRoomToWatch() {
        XCTAssertNil(LocalMediaTrackingPolicy.resumePosition(for: record(position: 9, duration: 3600)))
        XCTAssertEqual(LocalMediaTrackingPolicy.resumePosition(for: record(position: 900, duration: 3600)), 900)
        XCTAssertNil(LocalMediaTrackingPolicy.resumePosition(for: record(position: 3580, duration: 3600)))
        XCTAssertNil(LocalMediaTrackingPolicy.resumePosition(for: record(position: 900, duration: 3600, completed: true)))
    }

    func testCompletionUsesPercentageOrShortRemainingTail() {
        XCTAssertFalse(LocalMediaTrackingPolicy.isComplete(position: 5400, duration: 6000))
        XCTAssertTrue(LocalMediaTrackingPolicy.isComplete(position: 5520, duration: 6000))
        XCTAssertTrue(LocalMediaTrackingPolicy.isComplete(position: 3500, duration: 3600))
        XCTAssertFalse(LocalMediaTrackingPolicy.isComplete(position: 30, duration: 100))
    }

    func testStatusTextAndSeriesCardUseEpisodeProgress() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: movie, position: 600, duration: 6240)
        XCTAssertEqual(library.playbackStatus(for: movie), "1h 34m remaining")

        let episode = MediaItem(id: "episode", name: "Fourth", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 4, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
        library.trackPlayback(of: episode, position: 1560, duration: 3600)
        let series = MediaItem(id: "show", name: "Show", type: "Series", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        XCTAssertEqual(library.playbackStatus(for: series),
                       "Season 1, Episode 4 · 34 minutes left")
        XCTAssertEqual(library.displayedPlaybackRecord(for: series)?.item.id, episode.id)
    }

    func testFavoritesPersistAndLocalUnwatchedOverridesServer() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episode = MediaItem(id: "episode", name: "Episode", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            userData: MediaUserData(played: true, isFavorite: false, playedPercentage: 100))
        library.setLocalFavorite(true, for: episode)
        XCTAssertEqual(library.favoriteMedia.map(\.id), [episode.id])
        library.setLocallyPlayed(false, for: episode)
        XCTAssertFalse(library.isWatched(episode))
        XCTAssertTrue(library.continueWatching.isEmpty)

        let restored = MediaLibrary(defaults: defaults)
        XCTAssertEqual(restored.favoriteMedia.map(\.id), [episode.id])
        XCTAssertFalse(restored.isWatched(episode))
    }

    func testRemoveFromContinueWatchingForgetsOnlyThatResumePoint() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: movie, position: 900, duration: 5_400)
        XCTAssertTrue(library.isInContinueWatching(movie))

        library.removeFromContinueWatching(movie)

        XCTAssertFalse(library.isInContinueWatching(movie))
        XCTAssertNil(library.localPlaybackRecord(for: movie))
        XCTAssertTrue(library.watchHistory.isEmpty)
        XCTAssertFalse(library.isWatched(movie))
    }

    func testMDBListMatcherPrefersProviderIDsAndFallsBackToExactTitleYear() {
        let providerMatch = MediaItem(id: "server-1", name: "Renamed Film", type: "Movie",
            overview: nil, productionYear: 2024, primaryImageAspectRatio: nil, childCount: nil,
            providerIDs: ["Imdb": "tt1234567"])
        let titleMatch = MediaItem(id: "server-2", name: "The Show", type: "Series",
            overview: nil, productionYear: 2022, primaryImageAspectRatio: nil, childCount: nil)
        let entries = [
            MDBListCatalogItem(title: "Original Film", mediaType: "movie", releaseYear: 2024,
                imdbID: "tt1234567", tmdbID: nil, tvdbID: nil, rank: 1),
            MDBListCatalogItem(title: "The Show", mediaType: "show", releaseYear: 2022,
                imdbID: nil, tmdbID: nil, tvdbID: nil, rank: 2)
        ]

        XCTAssertEqual(MDBListCatalogMatcher.match(entries, to: [titleMatch, providerMatch]).map(\.id),
                       [providerMatch.id, titleMatch.id])
    }

    private func makeLibrary() throws -> (MediaLibrary, UserDefaults, String) {
        let suite = "LocalMediaTrackingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profile = MediaServerProfile(name: "Server", serverURL: "http://server",
            username: "viewer", userID: "user")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        defaults.set(profile.id.uuidString, forKey: "NullSports.activeMediaServer")
        return (MediaLibrary(defaults: defaults), defaults, suite)
    }
}
