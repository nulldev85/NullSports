import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

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
                       "S01E04 · 34 minutes left")
        XCTAssertEqual(library.displayedPlaybackRecord(for: series)?.item.id, episode.id)

        let serverWatchedEpisode = MediaItem(id: "episode-2", name: "Second", type: "Episode",
            overview: nil, productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 2, parentIndexNumber: 1,
            userData: MediaUserData(played: true, isFavorite: false, playedPercentage: 100))
        XCTAssertEqual(library.playbackStatus(for: serverWatchedEpisode), "S01E02 · Watched")

        let serverWatchedMovie = MediaItem(id: "movie-2", name: "Movie", type: "Movie",
            overview: nil, productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            userData: MediaUserData(played: true, isFavorite: false, playedPercentage: 100))
        XCTAssertEqual(library.playbackStatus(for: serverWatchedMovie), "Watched")
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

    func testRemoveFromContinueWatchingPreservesTheLatestResumePointAcrossRelaunch() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: movie, position: 900, duration: 5_400)
        library.trackPlayback(of: movie, position: 940, duration: 5_400)
        XCTAssertTrue(library.isInContinueWatching(movie))

        library.removeFromContinueWatching(movie)

        XCTAssertFalse(library.isInContinueWatching(movie))
        XCTAssertEqual(library.resumePosition(for: movie), 940)
        XCTAssertTrue(library.watchHistory.isEmpty)
        XCTAssertFalse(library.isWatched(movie))
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertFalse(restored.isInContinueWatching(movie))
        XCTAssertEqual(restored.resumePosition(for: movie), 940)
    }

    func testEpisodeWatchedAdvancesAndUnwatchedRollsContinueWatchingBack() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MediaItem(id: "e1", name: "First", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
        let second = MediaItem(id: "e2", name: "Second", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 2, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")

        library.applyLocalEpisodeProgression(true, for: first, following: second)
        XCTAssertTrue(library.isWatched(first))
        XCTAssertEqual(library.continueWatching.map(\.item.id), [second.id])
        XCTAssertEqual(library.localPlaybackRecord(for: second)?.isUpNext, true)

        library.applyLocalEpisodeProgression(false, for: first, following: nil)
        XCTAssertFalse(library.isWatched(first))
        XCTAssertEqual(library.continueWatching.map(\.item.id), [first.id])
        XCTAssertEqual(library.localPlaybackRecord(for: first)?.explicitlyUnwatched, true)
    }

    func testSeriesArtworkPrefersRealProgressOverGeneratedUpNext() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let series = MediaItem(id: "show", name: "Show", type: "Series", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        let previous = MediaItem(id: "s1e2", name: "Previous", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 2, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
        let current = MediaItem(id: "s1e3", name: "Current", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 3, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
        let generatedNext = MediaItem(id: "s2e1", name: "Generated", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 2, seriesName: "Show", seriesID: "show")

        library.trackPlayback(of: current, position: 600, duration: 3_600)
        library.applyLocalEpisodeProgression(true, for: previous, following: generatedNext)

        XCTAssertEqual(library.displayedPlaybackRecord(for: series)?.item.id, current.id)
        XCTAssertEqual(library.playbackStatus(for: series), "S01E03 · 50 minutes left")
        XCTAssertEqual(library.continueWatching.map(\.item.id), [current.id])

        library.applyLocalEpisodeProgression(false, for: previous, following: nil)

        XCTAssertEqual(library.displayedPlaybackRecord(for: series)?.item.id, previous.id)
        XCTAssertEqual(library.playbackStatus(for: series), "S01E02 · Next Ep.")
        XCTAssertEqual(library.continueWatching.map(\.item.id), [previous.id])
    }

    func testEpisodeProgressionCrossesSeasonsAndSkipsWatchedEpisodes() {
        let current = MediaItem(id: "s1e2", name: "Finale", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 2, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
        let watched = MediaItem(id: "s2e1", name: "Return", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 2, seriesName: "Show", seriesID: "show")
        let expected = MediaItem(id: "s2e2", name: "Next", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 2, parentIndexNumber: 2, seriesName: "Show", seriesID: "show")

        let next = LocalEpisodeProgressionPolicy.nextEpisode(
            after: current, in: [expected, current, watched], isWatched: { $0.id == watched.id })
        XCTAssertEqual(next?.id, expected.id)
    }

    func testRememberedNextEpisodeBecomesTheSeriesPositionWithoutOverridingProgress() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let series = MediaItem(id: "show", name: "Show", type: "Series", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        let third = MediaItem(id: "s1e3", name: "Third", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 3, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
        let fourth = MediaItem(id: "s1e4", name: "Fourth", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 4, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")

        library.rememberNextUp(third)
        XCTAssertEqual(library.displayedPlaybackRecord(for: series)?.item.id, third.id)
        XCTAssertEqual(library.playbackStatus(for: series), "S01E03 · Next Ep.")

        library.trackPlayback(of: third, position: 600, duration: 3_600)
        library.rememberNextUp(fourth)
        XCTAssertEqual(library.displayedPlaybackRecord(for: series)?.item.id, third.id)
        XCTAssertEqual(library.playbackStatus(for: series), "S01E03 · 50 minutes left")
    }

    func testPlayingProgressIsHeldUntilItMattersAndFlushedOnClose() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: movie, position: 600, duration: 6_000)
        // A first record goes straight in.
        XCTAssertEqual(library.continueWatching.first?.position, 600)

        library.trackPlayback(of: movie, position: 640, duration: 6_000)
        // The creep of a position is held, but reads still see it.
        XCTAssertEqual(library.continueWatching.first?.position, 600)
        XCTAssertEqual(library.resumePosition(for: movie), 640)

        library.flushLocalPlayback()
        XCTAssertEqual(library.continueWatching.first?.position, 640)
        XCTAssertEqual(MediaLibrary(defaults: defaults).resumePosition(for: movie), 640)
    }

    func testFinishingIsNeverHeldBack() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: movie, position: 600, duration: 6_000)
        library.trackPlayback(of: movie, position: 5_900, duration: 6_000)
        XCTAssertEqual(library.watchHistory.map(\.item.id), [movie.id])
        XCTAssertTrue(library.continueWatching.isEmpty)
    }

    func testNaturalEndMarksTwoEpisodesInANewSeasonAndSurvivesRelaunch() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episodes = (1...2).map { number in
            MediaItem(id: "s2e\(number)", name: "Episode \(number)", type: "Episode", overview: nil,
                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                indexNumber: number, parentIndexNumber: 2, seriesName: "Show", seriesID: "show")
        }
        for episode in episodes {
            library.trackPlayback(of: episode, position: 600, duration: 0)
            library.completePlayback(of: episode)
            library.flushLocalPlayback()
            XCTAssertTrue(library.isWatched(episode))
            XCTAssertTrue(library.cardPlayback(for: episode, asShow: false)?.watched == true)
        }
        let restored = MediaLibrary(defaults: defaults)
        for episode in episodes { XCTAssertTrue(restored.isWatched(episode)) }
    }

    func testMarkWatchedAndUnwatchedOverrideBufferedProgress() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: movie, position: 600, duration: 6_000)
        library.trackPlayback(of: movie, position: 700, duration: 6_000)
        library.setLocallyPlayed(true, for: movie)
        library.flushLocalPlayback()
        XCTAssertTrue(library.isWatched(movie))
        XCTAssertTrue(MediaLibrary(defaults: defaults).isWatched(movie))

        library.trackPlayback(of: movie, position: 600, duration: 6_000)
        library.trackPlayback(of: movie, position: 700, duration: 6_000)
        library.setLocallyPlayed(false, for: movie)
        library.flushLocalPlayback()
        XCTAssertFalse(library.isWatched(movie))
        XCTAssertTrue(library.continueWatching.isEmpty)
        XCTAssertFalse(MediaLibrary(defaults: defaults).isWatched(movie))
    }

    func testCompletionDistinguishesUnknownLengthEOFFromDroppedStreams() {
        XCTAssertTrue(LocalMediaTrackingPolicy.reachedEnd(ended: true, failed: true, hasPlayed: true,
            position: 2_400, duration: 0, fraction: -1))
        XCTAssertFalse(LocalMediaTrackingPolicy.reachedEnd(ended: false, failed: true, hasPlayed: true,
            position: 600, duration: 2_400, fraction: 0.25))
        XCTAssertFalse(LocalMediaTrackingPolicy.reachedEnd(ended: true, failed: true, hasPlayed: false,
            position: 0, duration: 2_400, fraction: 0))
        XCTAssertTrue(LocalMediaTrackingPolicy.reachedEnd(ended: false, failed: true, hasPlayed: true,
            position: 2_390, duration: 2_400, fraction: 0.99))
    }

    func testLateUpNextCannotEraseAFinishedEpisode() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MediaItem(id: "s2e1", name: "First", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 2, seriesName: "Show", seriesID: "show")
        let second = MediaItem(id: "s2e2", name: "Second", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 2, parentIndexNumber: 2, seriesName: "Show", seriesID: "show")
        library.setLocallyPlayed(true, for: second)
        library.applyLocalEpisodeProgression(true, for: first, following: second)
        XCTAssertTrue(library.isWatched(first))
        XCTAssertTrue(library.isWatched(second))
        XCTAssertFalse(library.continueWatching.contains { $0.item.id == second.id })
        XCTAssertTrue(MediaLibrary(defaults: defaults).isWatched(second))
    }

    func testMarkingAMovieUnwatchedDoesNotQueueItAsAnEpisode() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: movie, position: 600, duration: 6_000)
        library.applyLocalEpisodeProgression(false, for: movie, following: nil)
        XCTAssertFalse(library.isWatched(movie))
        XCTAssertTrue(library.continueWatching.isEmpty)
        XCTAssertNotEqual(library.localPlaybackRecord(for: movie)?.isUpNext, true)
    }

    func testAnotherTitleCommitsTheOneBeforeIt() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MediaItem(id: "first", name: "First", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        let second = MediaItem(id: "second", name: "Second", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: first, position: 600, duration: 6_000)
        library.trackPlayback(of: first, position: 700, duration: 6_000)
        library.trackPlayback(of: second, position: 60, duration: 6_000)
        XCTAssertEqual(library.continueWatching.first { $0.item.id == first.id }?.position, 700)
    }

    func testRemovingAShowHidesAllItsEpisodesWithoutLosingProgressOrHistory() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MediaItem(id: "e1", name: "First", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
        let second = MediaItem(id: "e2", name: "Second", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 2, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
        library.applyLocalEpisodeProgression(true, for: first, following: second)
        library.trackPlayback(of: second, position: 300, duration: 3_000)
        XCTAssertEqual(library.continueWatching.map(\.item.id), [second.id])

        library.removeFromContinueWatching(second)

        XCTAssertTrue(library.continueWatching.isEmpty)
        XCTAssertEqual(library.resumePosition(for: second), 300)
        XCTAssertTrue(library.isWatched(first))
        let series = MediaItem(id: "show", name: "Show", type: "Series", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertTrue(restored.continueWatching.isEmpty)
        XCTAssertEqual(restored.continueWatchingEpisode(in: series)?.id, second.id)
        XCTAssertEqual(restored.displayedPlaybackRecord(for: series)?.item.id, second.id)
        XCTAssertEqual(restored.resumePosition(for: second), 300)
        XCTAssertTrue(restored.isWatched(first))
    }

    func testClosingPlayerAndBackgroundSamplesCannotRestoreARemovedMovie() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = trackingMovie()
        let session = UUID()
        library.beginPlaybackSession(for: movie, id: session)
        library.trackPlayback(of: movie, position: 900, duration: 5_400, sessionID: session)
        library.removeFromContinueWatching(movie)
        library.trackPlayback(of: movie, position: 920, duration: 5_400, sessionID: session)
        library.flushLocalPlayback()
        XCTAssertFalse(library.isInContinueWatching(movie))
        XCTAssertEqual(library.resumePosition(for: movie), 920)
        library.endPlaybackSession(session)
        // Out-of-order progress and EOF after dismissal cannot overwrite it.
        library.trackPlayback(of: movie, position: 960, duration: 5_400, sessionID: session)
        library.completePlayback(of: movie, sessionID: session)
        library.trackPlayback(of: movie, position: 925, duration: 5_400)
        library.flushLocalPlayback()
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertFalse(restored.isInContinueWatching(movie))
        XCTAssertEqual(restored.resumePosition(for: movie), 925)
        XCTAssertFalse(restored.isWatched(movie))
    }

    func testActuallyResumingARemovedTitleRestoresItsCardAndUpdatesSavedProgress() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = trackingMovie()
        library.trackPlayback(of: movie, position: 900, duration: 5_400)
        library.removeFromContinueWatching(movie)
        let restored = MediaLibrary(defaults: defaults)
        let session = UUID()
        restored.beginPlaybackSession(for: movie, id: session)
        restored.trackPlayback(of: movie, position: 900, duration: 5_400, sessionID: session)
        XCTAssertFalse(restored.isInContinueWatching(movie), "An initial resume seek is not new viewing")
        restored.trackPlayback(of: movie, position: 904, duration: 5_400, sessionID: session)
        XCTAssertFalse(restored.isInContinueWatching(movie))
        restored.trackPlayback(of: movie, position: 910, duration: 5_400, sessionID: session)
        restored.endPlaybackSession(session)
        XCTAssertTrue(restored.isInContinueWatching(movie))
        let reopened = MediaLibrary(defaults: defaults)
        XCTAssertTrue(reopened.isInContinueWatching(movie))
        XCTAssertEqual(reopened.resumePosition(for: movie), 910)
    }

    func testBrieflyOpeningThenClosingARemovedTitleKeepsItHidden() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = trackingMovie()
        library.trackPlayback(of: movie, position: 900, duration: 5_400)
        library.removeFromContinueWatching(movie)
        let session = UUID()
        library.beginPlaybackSession(for: movie, id: session)
        library.trackPlayback(of: movie, position: 901, duration: 5_400, sessionID: session)
        library.endPlaybackSession(session)
        XCTAssertFalse(MediaLibrary(defaults: defaults).isInContinueWatching(movie))
        XCTAssertEqual(MediaLibrary(defaults: defaults).resumePosition(for: movie), 901)
    }

    func testASecondRemovalCannotBeUndoneByTheSessionThatWasAlreadyPlaying() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = trackingMovie()
        library.trackPlayback(of: movie, position: 900, duration: 5_400)
        library.removeFromContinueWatching(movie)
        let session = UUID()
        library.beginPlaybackSession(for: movie, id: session)
        library.trackPlayback(of: movie, position: 910, duration: 5_400, sessionID: session)
        XCTAssertTrue(library.isInContinueWatching(movie))
        library.removeFromContinueWatching(movie)
        library.trackPlayback(of: movie, position: 930, duration: 5_400, sessionID: session)
        library.endPlaybackSession(session)
        XCTAssertFalse(library.isInContinueWatching(movie))
        XCTAssertEqual(library.resumePosition(for: movie), 930)
    }

    func testStartOverRestoresARemovedMovieAfterPlaybackBegins() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = trackingMovie()
        library.trackPlayback(of: movie, position: 900, duration: 5_400)
        library.removeFromContinueWatching(movie)
        let session = UUID()
        library.beginPlaybackSession(for: movie, id: session, startsOver: true)
        library.trackPlayback(of: movie, position: 0, duration: 5_400, sessionID: session)
        XCTAssertFalse(library.isInContinueWatching(movie))
        XCTAssertEqual(library.resumePosition(for: movie), 900)
        library.trackPlayback(of: movie, position: 10, duration: 5_400, sessionID: session)
        library.endPlaybackSession(session)
        XCTAssertTrue(library.isInContinueWatching(movie))
        XCTAssertEqual(library.resumePosition(for: movie), 10)
    }

    func testRefreshedUpNextAndManualMarksNeverUnhideAShow() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = trackingEpisode(1)
        let second = trackingEpisode(2)
        let third = trackingEpisode(3)
        library.rememberNextUp(first)
        library.removeFromContinueWatching(first)
        library.rememberNextUp(second)
        library.applyLocalEpisodeProgression(true, for: second, following: third)
        library.applyLocalEpisodeProgression(false, for: first, following: nil)
        XCTAssertTrue(library.continueWatching.isEmpty)
        let restored = MediaLibrary(defaults: defaults)
        restored.rememberNextUp(third)
        XCTAssertTrue(restored.continueWatching.isEmpty)
        let session = UUID()
        restored.beginPlaybackSession(for: third, id: session)
        restored.trackPlayback(of: third, position: 60, duration: 3_600, sessionID: session)
        restored.endPlaybackSession(session)
        XCTAssertTrue(restored.isInContinueWatching(third))
        XCTAssertEqual(restored.continueWatching.map(\.item.id), [third.id])
        XCTAssertEqual(restored.localPlaybackRecord(for: first)?.explicitlyUnwatched, true)
        XCTAssertTrue(restored.isWatched(second))
    }

    func testUpNextRefreshPreservesManualUnwatchedHistory() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = trackingEpisode(1)
        let second = trackingEpisode(2)
        library.applyLocalEpisodeProgression(false, for: first, following: nil)
        library.rememberNextUp(second)
        XCTAssertEqual(library.localPlaybackRecord(for: first)?.explicitlyUnwatched, true)
        XCTAssertNotEqual(library.localPlaybackRecord(for: first)?.isUpNext, true)
        library.rememberNextUp(first)
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertEqual(restored.localPlaybackRecord(for: first)?.explicitlyUnwatched, true)
        XCTAssertEqual(restored.localPlaybackRecord(for: first)?.isUpNext, true)
        XCTAssertFalse(restored.isWatched(first))
    }

    func testMarkingAnotherEpisodeWatchedPreservesAnEarlierUnwatchedMark() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = trackingEpisode(1)
        let second = trackingEpisode(2)
        let third = trackingEpisode(3)
        library.applyLocalEpisodeProgression(false, for: first, following: nil)
        library.applyLocalEpisodeProgression(true, for: second, following: third)
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertEqual(restored.localPlaybackRecord(for: first)?.explicitlyUnwatched, true)
        XCTAssertFalse(restored.isWatched(first))
        XCTAssertTrue(restored.isWatched(second))
        XCTAssertEqual(restored.continueWatching.map(\.item.id), [third.id])
    }

    func testRemovalIsScopedToTheTitleAndItsServer() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let other = MediaServerProfile(name: "Other", serverURL: "http://other",
            username: "viewer", userID: "user")
        defaults.set(try JSONEncoder().encode(library.profiles + [other]), forKey: "NullSports.mediaServers")
        let both = MediaLibrary(defaults: defaults)
        let movie = trackingMovie().servedBy(try XCTUnwrap(both.profiles.first?.id))
        let elsewhere = movie.servedBy(other.id)
        let unrelated = trackingMovie("another")
        both.trackPlayback(of: movie, position: 900, duration: 5_400)
        both.trackPlayback(of: elsewhere, position: 600, duration: 5_400)
        both.trackPlayback(of: unrelated, position: 300, duration: 5_400)
        both.removeFromContinueWatching(movie)
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertFalse(restored.isInContinueWatching(movie))
        XCTAssertTrue(restored.isInContinueWatching(elsewhere))
        XCTAssertTrue(restored.isInContinueWatching(unrelated))
        XCTAssertEqual(restored.resumePosition(for: movie), 900)
        XCTAssertEqual(restored.resumePosition(for: elsewhere), 600)
    }

    func testShowRemovalSurvivesMetadataEnrichmentWithoutHidingDifferentKnownShows() {
        let profile = UUID()
        let first = trackingEpisode(1)
        let second = trackingEpisode(2)
        let nameOnly = MediaItem(id: first.id, name: first.name, type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil, seriesName: " SHÓW ")
        let removal = LocalContinueWatchingDismissal(item: nameOnly, profileID: profile)
        XCTAssertTrue(removal.matches(second, profileID: profile))
        XCTAssertFalse(removal.matches(second, profileID: UUID()))
        let identified = LocalContinueWatchingDismissal(item: first, profileID: profile)
        let differentShow = MediaItem(id: second.id, name: second.name, type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            seriesName: "Show", seriesID: "different-show")
        XCTAssertFalse(identified.matches(differentShow, profileID: profile))
        XCTAssertFalse(identified.matches(trackingMovie(), profileID: profile))
    }

    func testHiddenProgressIsNotEvictedByTheRecentHistoryLimit() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hidden = trackingMovie("hidden")
        library.trackPlayback(of: hidden, position: 900, duration: 5_400)
        library.removeFromContinueWatching(hidden)
        for index in 1...205 {
            library.trackPlayback(of: trackingMovie("movie-\(index)"), position: 60, duration: 5_400)
        }
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertEqual(restored.resumePosition(for: hidden), 900)
        XCTAssertFalse(restored.isInContinueWatching(hidden))
    }

    func testHiddenNameOnlyEpisodesRemainResumableWhenShowMetadataIsEnriched() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episode = MediaItem(id: "e1", name: "First", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 1, seriesName: " SHÓW ")
        let series = MediaItem(id: "show", name: "Show", type: "Series", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: episode, position: 900, duration: 3_600)
        library.removeFromContinueWatching(episode)
        let restored = MediaLibrary(defaults: defaults)
        restored.rememberNextUp(trackingEpisode(2))
        XCTAssertTrue(restored.continueWatching.isEmpty)
        XCTAssertEqual(restored.continueWatchingEpisode(in: series)?.id, episode.id)
        XCTAssertEqual(restored.resumePosition(for: episode), 900)
    }

    func testManualWatchedChangesAndCompletionRejectLaterSamplesFromThatSession() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = trackingMovie()
        for markWatched in [false, true] {
            let session = UUID()
            library.beginPlaybackSession(for: movie, id: session, startsOver: true)
            library.trackPlayback(of: movie, position: 900, duration: 5_400, sessionID: session)
            library.setLocallyPlayed(markWatched, for: movie)
            library.trackPlayback(of: movie, position: 930, duration: 5_400, sessionID: session)
            library.completePlayback(of: movie, sessionID: session)
            library.endPlaybackSession(session)
            XCTAssertEqual(library.isWatched(movie), markWatched)
        }
        let session = UUID()
        library.beginPlaybackSession(for: movie, id: session, startsOver: true)
        library.trackPlayback(of: movie, position: 900, duration: 5_400, sessionID: session)
        library.completePlayback(of: movie, sessionID: session)
        library.trackPlayback(of: movie, position: 930, duration: 5_400, sessionID: session)
        library.endPlaybackSession(session)
        XCTAssertTrue(MediaLibrary(defaults: defaults).isWatched(movie))
    }

    func testClearingLocalHistoryAlsoClearsRemovalsAndInvalidatesTheOldPlayer() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let movie = trackingMovie()
        let old = UUID()
        library.beginPlaybackSession(for: movie, id: old)
        library.trackPlayback(of: movie, position: 900, duration: 5_400, sessionID: old)
        library.removeFromContinueWatching(movie)
        library.clearLocalPlayback()
        library.trackPlayback(of: movie, position: 930, duration: 5_400, sessionID: old)
        library.endPlaybackSession(old)
        XCTAssertNil(library.resumePosition(for: movie))
        let restored = MediaLibrary(defaults: defaults)
        let next = UUID()
        restored.beginPlaybackSession(for: movie, id: next)
        restored.trackPlayback(of: movie, position: 60, duration: 5_400, sessionID: next)
        restored.endPlaybackSession(next)
        XCTAssertTrue(restored.isInContinueWatching(movie))
    }

    func testCardsCountAShowsEpisodesAndAFilmsTime() throws {
        let (library, defaults, suite) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let episodes = (1...16).map { number in
            MediaItem(id: "e\(number)", name: "Episode \(number)", type: "Episode", overview: nil,
                productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
                indexNumber: (number - 1) % 8 + 1, parentIndexNumber: (number - 1) / 8 + 1,
                seriesName: "Show", seriesID: "show")
        }
        let special = MediaItem(id: "special", name: "Special", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: 1, parentIndexNumber: 0, seriesName: "Show", seriesID: "show")
        let series = MediaItem(id: "show", name: "Show", type: "Series", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: episodes[7], position: 1_000, duration: 3_000)

        // Until the show's episodes are known, the code stands in.
        XCTAssertEqual(library.cardPlayback(for: series, asShow: true)?.label, "S1 · E8")
        XCTAssertNil(library.cardPlayback(for: series, asShow: true)?.episodeFraction)

        library.learnEpisodeOrder(episodes + [special])
        let show = try XCTUnwrap(library.cardPlayback(for: series, asShow: true))
        XCTAssertEqual(show.label, "8 of 16")
        XCTAssertEqual(try XCTUnwrap(show.episodeFraction), 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(show.fraction, (7 + 1.0 / 3) / 16, accuracy: 0.001)

        // An episode's own still counts time, not episodes.
        XCTAssertEqual(library.cardPlayback(for: episodes[7], asShow: false)?.label, "34m left")

        let movie = MediaItem(id: "movie", name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
        library.trackPlayback(of: movie, position: 600, duration: 6_240)
        XCTAssertEqual(library.cardPlayback(for: movie, asShow: false)?.label, "1h 34m left")
        library.trackPlayback(of: movie, position: 6_200, duration: 6_240)
        XCTAssertEqual(library.cardPlayback(for: movie, asShow: false)?.label, "Watched")
        XCTAssertEqual(library.cardPlayback(for: movie, asShow: false)?.watched, true)
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

    func testMDBListCatalogsIncludeWrappedLikedListsAndDeduplicateSources() throws {
        let owned = try MDBListClient.parseCatalogs([
            ["id": 11, "name": "My Queue", "items": 12]
        ], section: .yourLists)
        let liked = try MDBListClient.parseCatalogs([
            "lists": [
                ["id": 11, "name": "My Queue", "items": 12],
                ["id": 22, "name": "Great Sci-Fi", "items": 80]
            ]
        ], wrapperKey: "lists", section: .liked)

        let merged = MDBListClient.mergeCatalogs(owned + liked)
        XCTAssertEqual(merged.map(\.id), [11, 22])
        XCTAssertEqual(merged.map(\.section), [.yourLists, .liked])
    }

    private func trackingMovie(_ id: String = "movie") -> MediaItem {
        MediaItem(id: id, name: "Movie", type: "Movie", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil)
    }

    private func trackingEpisode(_ number: Int) -> MediaItem {
        MediaItem(id: "e\(number)", name: "Episode \(number)", type: "Episode", overview: nil,
            productionYear: nil, primaryImageAspectRatio: nil, childCount: nil,
            indexNumber: number, parentIndexNumber: 1, seriesName: "Show", seriesID: "show")
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
