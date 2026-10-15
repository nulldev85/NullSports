import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

@MainActor
final class SeriesTrackingConsistencyTests: XCTestCase {
    private var show: MediaItem {
        MediaItem(id: "show", name: "Show", type: "Series", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
    }
    private var episodes: [MediaItem] {
        (1...12).map { number in
            MediaItem(id: "s2e\(number)", name: "Episode \(number)", type: "Episode", overview: nil,
                productionYear: nil, primaryImageAspectRatio: 16.0 / 9, childCount: nil,
                indexNumber: number, parentIndexNumber: 2, seriesName: "Show", seriesID: "show",
                posterURL: "https://example.invalid/episode-\(number).jpg")
        }
    }

    private func makeLibrary() throws -> (MediaLibrary, UserDefaults, String) {
        let suite = "SeriesTrackingConsistency.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profile = MediaServerProfile(name: "Offline", serverURL: "http://server.invalid",
            username: "viewer", userID: "user")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        defaults.set(profile.id.uuidString, forKey: "NullSports.activeMediaServer")
        return (MediaLibrary(defaults: defaults), defaults, suite)
    }

    private func assertPosition(_ library: MediaLibrary, episode: MediaItem,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(library.seriesPlayTarget(in: show)?.id, episode.id, file: file, line: line)
        XCTAssertEqual(library.continueWatchingEpisode(in: show)?.id, episode.id, file: file, line: line)
        XCTAssertEqual(library.continueWatching.map(\.item.id), [episode.id], file: file, line: line)
        XCTAssertEqual(library.displayedPlaybackRecord(for: show)?.item.id, episode.id, file: file, line: line)
        XCTAssertEqual(library.continueWatching.first?.item.posterURL, episode.posterURL, file: file, line: line)
    }

    func testWatchedChangesImmediatelyUpdateEveryPositionAndThumbnailWhileOffline() async throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episodes = self.episodes
        library.learnEpisodeOrder(episodes)
        library.rememberNextUp(episodes[0])
        assertPosition(library, episode: episodes[0])

        // Same entry point used by the Continue Watching and episode menus.
        await library.setEpisodePlayedAndAdvance(true, for: episodes[0])
        assertPosition(library, episode: episodes[1])
        XCTAssertTrue(library.isWatched(episodes[0]))
        XCTAssertTrue(library.cardPlayback(for: episodes[0], asShow: false)?.watched == true)

        await library.setEpisodePlayedAndAdvance(true, for: episodes[1])
        assertPosition(library, episode: episodes[2])
        await library.setEpisodePlayedAndAdvance(false, for: episodes[0])
        assertPosition(library, episode: episodes[0])
        XCTAssertFalse(library.isWatched(episodes[0]))

        await library.setEpisodePlayedAndAdvance(true, for: episodes[0])
        assertPosition(library, episode: episodes[2])
        let restored = MediaLibrary(defaults: defaults)
        restored.learnEpisodeOrder(episodes)
        assertPosition(restored, episode: episodes[2])
        XCTAssertTrue(restored.isWatched(episodes[0]))
        XCTAssertTrue(restored.isWatched(episodes[1]))
    }

    func testOldSeasonTwoEpisodeTenMarkerIsRepairedAndPersists() throws {
        let (initial, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try XCTUnwrap(initial.profiles.first?.id)
        let episodes = self.episodes
        let old = [
            LocalMediaPlayback(profileID: server, item: episodes[0], position: 3_000, duration: 3_000,
                updatedAt: Date(timeIntervalSince1970: 1), completed: true),
            LocalMediaPlayback(profileID: server, item: episodes[1], position: 3_000, duration: 3_000,
                updatedAt: Date(timeIntervalSince1970: 2), completed: true),
            LocalMediaPlayback(profileID: server, item: episodes[9], position: 0, duration: 3_000,
                updatedAt: Date(timeIntervalSince1970: 3), completed: false, isUpNext: true)
        ]
        defaults.set(try JSONEncoder().encode(old), forKey: "Lineup.localMediaPlayback.v1")
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertTrue(restored.continueWatching.isEmpty, "Do not expose the old E10 marker before repair")
        XCTAssertNotEqual(restored.displayedPlaybackRecord(for: show)?.item.id, episodes[9].id)
        restored.reconcileSeriesPlayback(in: show, episodes: Array(episodes.reversed()), serverNext: episodes[9])
        assertPosition(restored, episode: episodes[2])
        let reopened = MediaLibrary(defaults: defaults)
        reopened.learnEpisodeOrder(episodes)
        assertPosition(reopened, episode: episodes[2])
    }

    func testLateServerResponseUsesNewerManualChanges() async throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episodes = self.episodes
        library.learnEpisodeOrder(episodes)
        library.setLocallyPlayed(true, for: episodes[0])
        library.setLocallyPlayed(true, for: episodes[1])
        var response: CheckedContinuation<[MediaItem], Never>?
        let started = expectation(description: "Older request started")
        let late = Task {
            let snapshot = await withCheckedContinuation { response = $0; started.fulfill() }
            library.reconcileSeriesPlayback(in: self.show, episodes: snapshot, serverNext: episodes[9])
        }
        await fulfillment(of: [started], timeout: 2)
        library.setLocallyPlayed(false, for: episodes[0])
        let pending = try XCTUnwrap(response)
        pending.resume(returning: episodes)
        await late.value
        assertPosition(library, episode: episodes[0])
        XCTAssertFalse(library.isWatched(episodes[0]))
        XCTAssertTrue(library.isWatched(episodes[1]))
    }

    func testLocalProgressWinsOverRemoteJumpAndOldPartialPosition() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episodes = self.episodes
        library.learnEpisodeOrder(episodes)
        library.trackPlayback(of: episodes[0], position: 600, duration: 3_000)
        library.setLocallyPlayed(true, for: episodes[1])
        library.reconcileSeriesPlayback(in: show, episodes: episodes, serverNext: episodes[9])
        assertPosition(library, episode: episodes[2])
        XCTAssertEqual(library.resumePosition(for: episodes[0]), 600, "Old progress is retained for deliberate replay")
        library.trackPlayback(of: episodes[2], position: 700, duration: 3_000)
        library.reconcileSeriesPlayback(in: show, episodes: episodes, serverNext: episodes[9])
        assertPosition(library, episode: episodes[2])
        library.setLocallyPlayed(false, for: episodes[0])
        assertPosition(library, episode: episodes[0])
    }

    func testRemoteWatchedFlagsAheadCannotSkipTheLocalSeason() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let remote = self.episodes.map { episode in
            MediaItem(id: episode.id, name: episode.name, type: "Episode", overview: nil,
                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                indexNumber: episode.indexNumber, parentIndexNumber: 2, seriesName: "Show", seriesID: "show",
                userData: MediaUserData(played: (episode.indexNumber ?? 0) < 10, isFavorite: false, playedPercentage: 100),
                posterURL: episode.posterURL)
        }
        library.setLocallyPlayed(true, for: remote[0])
        library.setLocallyPlayed(true, for: remote[1])
        library.reconcileSeriesPlayback(in: show, episodes: remote, serverNext: remote[9])
        assertPosition(library, episode: remote[2])
        XCTAssertFalse(library.isWatched(remote[2]))
        library.setLocallyPlayed(true, for: remote[3])
        XCTAssertTrue(library.isWatched(remote[3]), "An explicit local mark still wins")
    }

    func testWholeShowMarksAndIndividualUnwatchedStayConsistent() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episodes = self.episodes
        library.learnEpisodeOrder(episodes)
        library.setLocallyPlayed(true, for: show)
        XCTAssertTrue(episodes.allSatisfy { library.isWatched($0) })
        XCTAssertTrue(library.isWatched(show))
        XCTAssertTrue(library.continueWatching.isEmpty)
        library.setLocallyPlayed(false, for: episodes[1])
        XCTAssertFalse(library.isWatched(show))
        assertPosition(library, episode: episodes[1])
        library.setLocallyPlayed(false, for: show)
        XCTAssertTrue(episodes.allSatisfy { !library.isWatched($0) })
        assertPosition(library, episode: episodes[0])
    }

    func testSeasonFinaleAdvancesToTheNextSeason() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MediaItem(id: "s3e1", name: "Return", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 3, seriesName: "Show", seriesID: "show",
            posterURL: "https://example.invalid/next-season.jpg")
        library.learnEpisodeOrder([first] + episodes)
        library.setLocallyPlayed(true, for: episodes[11])
        assertPosition(library, episode: first)
    }

    func testMatchingShowIDsOnDifferentServersKeepSeparatePositions() throws {
        let (initial, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try XCTUnwrap(initial.profiles.first)
        let other = MediaServerProfile(name: "Other", serverURL: "http://other.invalid",
            username: "viewer", userID: "user")
        defaults.set(try JSONEncoder().encode([first, other]), forKey: "NullSports.mediaServers")
        let library = MediaLibrary(defaults: defaults)
        let local = episodes.map { $0.servedBy(first.id) }
        let remote = episodes.map { $0.servedBy(other.id) }
        library.learnEpisodeOrder(local)
        library.learnEpisodeOrder(remote)
        library.setLocallyPlayed(true, for: local[0])
        library.setLocallyPlayed(true, for: local[1])
        library.trackPlayback(of: remote[8], position: 700, duration: 3_000)
        library.setLocallyPlayed(false, for: remote[1])
        XCTAssertEqual(library.seriesPlayTarget(in: show.servedBy(first.id))?.id, local[2].id)
        XCTAssertEqual(library.seriesPlayTarget(in: show.servedBy(other.id))?.id, remote[1].id)
        XCTAssertTrue(library.isWatched(local[1]))
        XCTAssertFalse(library.isWatched(remote[1]))
        XCTAssertEqual(library.continueWatching.count, 2)
    }

    func testCompletionCannotBeReversedByLateSessionProgress() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episodes = self.episodes
        library.learnEpisodeOrder(episodes)
        let session = UUID()
        library.beginPlaybackSession(for: episodes[0], id: session)
        library.trackPlayback(of: episodes[0], position: 600, duration: 3_000, sessionID: session)
        library.trackPlayback(of: episodes[0], position: 2_900, duration: 3_000, sessionID: session)
        library.trackPlayback(of: episodes[0], position: 700, duration: 3_000, sessionID: session)
        library.endPlaybackSession(session)
        XCTAssertTrue(library.isWatched(episodes[0]))
        assertPosition(library, episode: episodes[1])
    }

    func testLegacyNameOnlyMarkersRetireWithoutLosingTheUnwatchedChoice() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = MediaItem(id: "s2e1", name: "Episode 1", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 2, seriesName: " SHÓW ")
        library.setLocallyPlayed(false, for: legacy)
        library.learnEpisodeOrder(episodes)
        library.setLocallyPlayed(true, for: episodes[1])
        assertPosition(library, episode: episodes[2])
        XCTAssertFalse(library.isWatched(episodes[0]))
        XCTAssertEqual(library.localPlaybackRecord(for: episodes[0])?.explicitlyUnwatched, true)
        XCTAssertNotEqual(library.localPlaybackRecord(for: episodes[0])?.isUpNext, true)
    }

    func testProviderEpisodeMenusAdvanceFromTheLoadedOrder() async throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let providerShow = MediaItem(id: "iptv:series:42", name: "Provider Show", type: "Series", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        let values = (1...3).map { number in
            MediaItem(id: "iptv:episode:42:\(number)", name: "Episode \(number)", type: "Episode", overview: nil,
                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                indexNumber: number, parentIndexNumber: 1, seriesName: "Provider Show", seriesID: providerShow.id)
        }
        library.learnEpisodeOrder(values)
        await library.setEpisodePlayedAndAdvance(true, for: values[0])
        XCTAssertEqual(library.seriesPlayTarget(in: providerShow)?.id, values[1].id)
        XCTAssertEqual(library.continueWatching.map(\.item.id), [values[1].id])
        await library.setEpisodePlayedAndAdvance(false, for: values[0])
        XCTAssertEqual(library.continueWatching.map(\.item.id), [values[0].id])
        XCTAssertFalse(library.isWatched(values[0]))
    }

    func testWatchedAndUnwatchedTruthSurvivesTheRecentHistoryLimit() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episodes = self.episodes
        library.setLocallyPlayed(true, for: episodes[0])
        library.setLocallyPlayed(false, for: episodes[1])
        for index in 1...205 {
            let movie = MediaItem(id: "movie-\(index)", name: "Movie", type: "Movie", overview: nil,
                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
            library.trackPlayback(of: movie, position: 600, duration: 3_000)
        }
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertTrue(restored.isWatched(episodes[0]))
        XCTAssertEqual(restored.localPlaybackRecord(for: episodes[1])?.explicitlyUnwatched, true)
    }
}
