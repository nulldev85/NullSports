import XCTest
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

@MainActor
final class MDBListTrackingTests: XCTestCase {
    private let key = "test-personal-tracking-key"
    private let movieTarget = MDBListTrackingTarget(kind: .movie, ids: ["imdb": "tt0133093"])

    nonisolated override func tearDown() {
        TrackingTestProtocol.install { _ in (500, [:], "{}") }
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrackingTestProtocol.self]
        return URLSession(configuration: config)
    }
    private func defaults() throws -> UserDefaults {
        let name = "MDBListTrackingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func event(_ action: MDBListTrackingWrite.Action, progress: Double = 25,
                       session: UUID? = nil, target: MDBListTrackingTarget? = nil) -> MDBListTrackingWrite {
        .init(id: UUID(), sessionID: session, target: target ?? movieTarget, action: action,
              progress: progress, occurredAt: Date())
    }
    private func eventually(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), description)
        if !condition() { throw NSError(domain: "MDBListTrackingTests", code: 1) }
    }
    private func makeLibrary(_ defaults: UserDefaults, mdb: Bool = false) throws -> (MediaLibrary, MediaItem) {
        let profile = MediaServerProfile(name: "Jellyfin", serverURL: "https://server.invalid", username: "viewer", userID: "user")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "NullSports.mediaServers")
        defaults.set(mdb, forKey: LibraryTrackingPreferences.mdbKey)
        defaults.set(try JSONEncoder().encode(MDBListTrackingAccount(userID: 7,
            keyDigest: MDBListTrackingAccount.digest(key))), forKey: LibraryTrackingPreferences.accountKey)
        let movie = MediaItem(id: "matrix", name: "The Matrix", type: "Movie", overview: nil,
            productionYear: 1999, primaryImageAspectRatio: nil, childCount: nil,
            runTimeTicks: 36_000_000_000, providerIDs: ["Imdb": "tt0133093"]).servedBy(profile.id)
        let library = MediaLibrary(defaults: defaults, metadataCredentials: .init(tmdb: "", tvdb: ""),
            trackingSession: session(), trackingKey: { self.key })
        return (library, movie)
    }
    nonisolated private static func emptyResponse(_ request: URLRequest) -> (Int, [String: String], String) {
        switch request.url!.path {
        case "/sync/watched": return (200, [:], #"{"movies":[],"episodes":[],"pagination":{"next_cursor":null}}"#)
        case "/sync/playback": return (200, [:], "[]")
        case "/upnext": return (200, [:], #"{"items":[]}"#)
        default: return (200, [:], #"{"action":"pause","updated":{"movies":1},"deleted":{"movies":1}}"#)
        }
    }

    func testLocalIsDefaultAndDisablingBothPreservesDeviceHistory() throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let defaults = try defaults()
        let (library, movie) = try makeLibrary(defaults)
        XCTAssertTrue(library.localTrackingEnabled)
        XCTAssertFalse(library.mdbListTrackingEnabled)
        library.trackPlayback(of: movie, position: 450, duration: 3600)
        library.flushLocalPlayback()
        let saved = defaults.data(forKey: "Lineup.localMediaPlayback.v1")
        library.setLocalTrackingEnabled(false)
        XCTAssertTrue(library.localPlayback.isEmpty)
        library.trackPlayback(of: movie, position: 900, duration: 3600)
        library.setLocallyPlayed(true, for: movie)
        library.flushLocalPlayback()
        XCTAssertEqual(defaults.data(forKey: "Lineup.localMediaPlayback.v1"), saved)
        XCTAssertTrue(library.localPlayback.isEmpty)
        let restored = MediaLibrary(defaults: defaults, trackingKey: { nil })
        XCTAssertFalse(restored.localTrackingEnabled)
        library.setLocalTrackingEnabled(true)
        XCTAssertEqual(library.resumePosition(for: movie), 450)
        XCTAssertEqual(TrackingTestProtocol.requests.count, 0)
    }

    func testTrackersHaveSeparateCachesAndLocalWinsWhenBothEnabled() throws {
        TrackingTestProtocol.install { _ in (401, [:], "{}") }
        let defaults = try defaults()
        let (library, movie) = try makeLibrary(defaults)
        library.trackPlayback(of: movie, position: 470, duration: 3600)
        library.flushLocalPlayback()
        let local = defaults.data(forKey: "Lineup.localMediaPlayback.v1")
        let remote = LocalMediaPlayback(profileID: movie.serverID!, item: movie, position: 830, duration: 3600,
                                       updatedAt: Date(), completed: false)
        defaults.set(try JSONEncoder().encode([remote]), forKey: LibraryTrackingPreferences.cacheKey(7))
        library.setMDBListTrackingEnabled(true)
        XCTAssertEqual(library.resumePosition(for: movie), 470)
        library.setLocalTrackingEnabled(false)
        XCTAssertEqual(library.resumePosition(for: movie), 830)
        library.setLocalTrackingEnabled(true)
        XCTAssertEqual(library.resumePosition(for: movie), 470)
        XCTAssertEqual(defaults.data(forKey: "Lineup.localMediaPlayback.v1"), local)
        library.setMDBListTrackingEnabled(false)
    }

    func testPlayerStartPauseFinalStopAndStaleCallbackIsolation() async throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let defaults = try defaults()
        let (library, movie) = try makeLibrary(defaults, mdb: true)
        defer { library.setMDBListTrackingEnabled(false) }
        let id = UUID()
        library.beginPlaybackSession(for: movie, id: id)
        XCTAssertTrue(TrackingTestProtocol.posts.isEmpty, "Opening a source is not a scrobble")
        library.reportTrackingSample(.init(playing: true, pictureInPicture: false, position: 600, duration: 3600), for: movie, sessionID: id)
        try await eventually("actual playback sends start") { TrackingTestProtocol.posts.count == 1 }
        library.reportTrackingSample(.init(playing: false, pictureInPicture: false, position: 900, duration: 3600), for: movie, sessionID: id)
        try await eventually("pause is saved") { TrackingTestProtocol.posts.count == 2 }
        // Engine teardown resets its clock: stop must retain the last real point.
        library.reportTrackingSample(.init(playing: false, pictureInPicture: false, position: 0, duration: 0), for: movie, sessionID: id)
        library.endPlaybackSession(id)
        try await eventually("closing sends final stop") { TrackingTestProtocol.posts.count == 3 }
        library.reportTrackingSample(.init(playing: true, pictureInPicture: false, position: 1600, duration: 3600), for: movie, sessionID: id)
        XCTAssertEqual(TrackingTestProtocol.posts.map { $0.url!.path }, ["/scrobble/start", "/scrobble/pause", "/scrobble/stop"])
        let body = try TrackingTestProtocol.posts[2].trackingBody()
        XCTAssertEqual(body["progress"] as? Double, 25)
        XCTAssertEqual(body["app_name"] as? String, "Lineup")
        XCTAssertEqual(library.resumePosition(for: movie), 900)
    }

    func testMDBListOnlyPlaybackNeverWritesDeviceHistory() async throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let defaults = try defaults()
        let (library, movie) = try makeLibrary(defaults)
        library.trackPlayback(of: movie, position: 420, duration: 3600)
        library.flushLocalPlayback()
        let saved = defaults.data(forKey: "Lineup.localMediaPlayback.v1")
        library.setLocalTrackingEnabled(false)
        library.setMDBListTrackingEnabled(true)
        defer { library.setMDBListTrackingEnabled(false) }
        let id = UUID()
        library.beginPlaybackSession(for: movie, id: id)
        library.reportTrackingSample(.init(playing: true, pictureInPicture: false, position: 600, duration: 3600), for: movie, sessionID: id)
        try await eventually("remote-only start sent") { TrackingTestProtocol.posts.count == 1 }
        library.reportTrackingSample(.init(playing: false, pictureInPicture: false, position: 2952, duration: 3600), for: movie, sessionID: id)
        library.endPlaybackSession(id)
        try await eventually("remote-only stop sent") { TrackingTestProtocol.posts.contains { $0.url?.path == "/scrobble/stop" } }
        XCTAssertTrue(library.isWatched(movie))
        XCTAssertEqual(defaults.data(forKey: "Lineup.localMediaPlayback.v1"), saved)
        library.setLocalTrackingEnabled(true)
        XCTAssertEqual(library.resumePosition(for: movie), 420)
    }

    func testOpeningThenClosingNeverSendsRemoteActivity() async throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let (library, movie) = try makeLibrary(try defaults(), mdb: true)
        defer { library.setMDBListTrackingEnabled(false) }
        let id = UUID()
        library.beginPlaybackSession(for: movie, id: id)
        library.reportTrackingSample(.init(playing: false, pictureInPicture: false, position: 0, duration: 3600), for: movie, sessionID: id)
        library.endPlaybackSession(id)
        try await eventually("initial read completes") { library.mdbListTracking.lastSynced != nil }
        XCTAssertTrue(TrackingTestProtocol.posts.isEmpty)
    }

    func testLocalCompletionDoesNotRetireRemoteFinalStop() async throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let (library, movie) = try makeLibrary(try defaults(), mdb: true)
        defer { library.setMDBListTrackingEnabled(false) }
        let id = UUID()
        library.beginPlaybackSession(for: movie, id: id)
        library.reportTrackingSample(.init(playing: true, pictureInPicture: false, position: 3400, duration: 3600), for: movie, sessionID: id)
        try await eventually("start sent") { TrackingTestProtocol.posts.count == 1 }
        XCTAssertTrue(library.isWatched(movie))
        library.completePlayback(of: movie, sessionID: id)
        library.endPlaybackSession(id)
        try await eventually("EOF sends one stop at 100") { TrackingTestProtocol.posts.count == 2 }
        XCTAssertEqual(TrackingTestProtocol.posts[1].url!.path, "/scrobble/stop")
        XCTAssertEqual(try TrackingTestProtocol.posts[1].trackingBody()["progress"] as? Double, 100)
    }

    func testMDBListCompletionRuleDoesNotChangeLocalHistory() async throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let defaults = try defaults()
        let (library, movie) = try makeLibrary(defaults, mdb: true)
        defer { library.setMDBListTrackingEnabled(false) }
        let id = UUID()
        library.beginPlaybackSession(for: movie, id: id)
        library.reportTrackingSample(.init(playing: true, pictureInPicture: false, position: 2952, duration: 3600), for: movie, sessionID: id)
        try await eventually("start sent") { TrackingTestProtocol.posts.count == 1 }
        library.reportTrackingSample(.init(playing: false, pictureInPicture: false, position: 2952, duration: 3600), for: movie, sessionID: id)
        try await eventually("pause sent") { TrackingTestProtocol.posts.count == 2 }
        library.endPlaybackSession(id)
        XCTAssertFalse(library.isWatched(movie), "82% is below the local rule")
        let remote = try JSONDecoder().decode([LocalMediaPlayback].self,
            from: XCTUnwrap(defaults.data(forKey: LibraryTrackingPreferences.cacheKey(7))))
        XCTAssertTrue(try XCTUnwrap(remote.first).completed, "MDBList pauses at 80% mark watched")
    }

    func testPiPContinuesTrackingAfterPresentationEndsThenStopsOnce() async throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let (library, movie) = try makeLibrary(try defaults(), mdb: true)
        defer { library.setMDBListTrackingEnabled(false) }
        let id = UUID()
        library.beginPlaybackSession(for: movie, id: id)
        library.reportTrackingSample(.init(playing: true, pictureInPicture: true, position: 600, duration: 3600), for: movie, sessionID: id)
        try await eventually("PiP starts") { TrackingTestProtocol.posts.count == 1 }
        library.endPlaybackSession(id)
        XCTAssertEqual(TrackingTestProtocol.posts.count, 1)
        library.reportTrackingSample(.init(playing: true, pictureInPicture: true, position: 900, duration: 3600), for: movie, sessionID: id)
        library.reportTrackingSample(.init(playing: false, pictureInPicture: false, position: 900, duration: 3600), for: movie, sessionID: id)
        try await eventually("PiP close stops") { TrackingTestProtocol.posts.count == 2 }
        XCTAssertEqual(try TrackingTestProtocol.posts.last!.trackingBody()["progress"] as? Double, 25)
    }

    func testManualUnwatchedRetiresOldPlayerAndUsesExplicitHistoryEndpoint() async throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let (library, movie) = try makeLibrary(try defaults(), mdb: true)
        defer { library.setMDBListTrackingEnabled(false) }
        let id = UUID()
        library.beginPlaybackSession(for: movie, id: id)
        library.reportTrackingSample(.init(playing: true, pictureInPicture: false, position: 600, duration: 3600), for: movie, sessionID: id)
        try await eventually("start sent") { TrackingTestProtocol.posts.count == 1 }
        library.setLocallyPlayed(false, for: movie)
        try await eventually("manual removal sent") { TrackingTestProtocol.posts.count == 2 }
        library.reportTrackingSample(.init(playing: true, pictureInPicture: false, position: 1200, duration: 3600), for: movie, sessionID: id)
        library.endPlaybackSession(id)
        XCTAssertEqual(TrackingTestProtocol.posts.last?.url?.path, "/sync/watched/remove")
        XCTAssertEqual(TrackingTestProtocol.posts.count, 2)
        XCTAssertTrue(library.localPlaybackRecord(for: movie)?.explicitlyUnwatched == true)
    }

    func testEpisodeMappingUsesVerifiedTVDBEpisodeNotDisplayNumbers() async throws {
        TrackingTestProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/3/find/222222")
            return (200, [:], #"{"tv_episode_results":[{"id":111111,"show_id":1000,"season_number":2,"episode_number":5}]}"#)
        }
        let resolver = LibraryMetadataResolver(credentials: .init(tmdb: "test-token", tvdb: ""), session: session(), cacheURL: nil)
        let show = MediaItem(id: "show", name: "Show", type: "Series", overview: nil, productionYear: nil,
            primaryImageAspectRatio: nil, childCount: nil, providerIDs: ["Tmdb": "1000"])
        let episode = MediaItem(id: "episode", name: "Episode", type: "Episode", overview: nil, productionYear: nil,
            primaryImageAspectRatio: nil, childCount: nil, indexNumber: 5, parentIndexNumber: 23, providerIDs: ["Tvdb": "222222"])
        let target = await resolver.mdbTrackingEpisode(episode, parent: show, source: .tvdb)
        XCTAssertEqual(target?.season, 2)
        XCTAssertEqual(target?.episode, 5)
        XCTAssertEqual(target?.episodeIDs["tmdb"], "111111")
        let body = try XCTUnwrap(target).watchedBody(at: Date())
        XCTAssertEqual((body["episodes"] as? [[String: Any]])?.first?["ids"] as? [String: Int], ["tvdb": 222222, "tmdb": 111111])
        TrackingTestProtocol.install { _ in (200, [:], #"{"tv_episode_results":[{"id":111111,"show_id":999,"season_number":2,"episode_number":5}]}"#) }
        let wrong = await resolver.mdbTrackingEpisode(episode, parent: show, source: .tvdb)
        XCTAssertNil(wrong, "Another show's episode must never be scrobbled")
    }

    func testIncomingEpisodeMatchingIsNamespacedAndRequiresNumberingEvidence() {
        let show = MediaItem(id: "show", name: "Show", type: "Series", overview: nil, productionYear: nil,
            primaryImageAspectRatio: nil, childCount: nil, providerIDs: ["Tmdb": "1000", "Tvdb": "3000"])
        let episode = MediaItem(id: "episode", name: "Episode", type: "Episode", overview: nil, productionYear: nil,
            primaryImageAspectRatio: nil, childCount: nil, indexNumber: 5, parentIndexNumber: 23)
        var target = MDBListTrackingTarget(kind: .episode, ids: ["tmdb": "1000"], season: 2, episode: 5)
        XCTAssertFalse(MediaLibrary.matchesMDBEpisode(episode, series: show, target: target, source: .tvdb))
        XCTAssertFalse(MediaLibrary.matchesMDBEpisode(episode, series: show, target: target, source: .tmdb))
        target.tvdbSeason = 23; target.tvdbEpisode = 5; target.tvdbSeries = "3000"
        XCTAssertTrue(MediaLibrary.matchesMDBEpisode(episode, series: show, target: target, source: .tvdb))
        XCTAssertFalse(MediaLibrary.matchesMDBEpisode(episode, series: show, target: target, source: .provider))
        XCTAssertNotEqual(movieTarget.key, MDBListTrackingTarget(kind: .show, ids: movieTarget.ids).key)
        XCTAssertFalse(MDBListTrackingTarget(kind: .movie, ids: ["imdb": "bad"]).valid)
    }

    func testCompleteCursorSnapshotReadsHistoryPlaybackAndUpNext() async throws {
        let key = key
        TrackingTestProtocol.install { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "apikey" }?.value, key)
            switch request.url!.path {
            case "/sync/watched":
                if query.first(where: { $0.name == "mediatype" })?.value == "episode" {
                    return (200, [:], #"{"episodes":[{"last_watched_at":"2026-10-17T21:30:00.000Z","episode":{"season":2,"number":5,"ids":{"tmdb":111111},"show":{"ids":{"tmdb":1000}},"tvdb_ids":{"series":3000,"season":23,"episode":5}}}],"pagination":{"next_cursor":null}}"#)
                }
                if query.contains(where: { $0.name == "cursor" }) { return (200, [:], #"{"movies":[],"pagination":{"next_cursor":null}}"#) }
                return (200, [:], #"{"movies":[{"watched_at":"2026-10-17T21:30:00Z","movie":{"ids":{"imdb":"tt0133093"}}}],"pagination":{"next_cursor":"page2"}}"#)
            case "/sync/playback": return (200, [:], #"[{"progress":25.0,"updated_at_ts":1792272600,"runtime":120,"movie":{"ids":{"tmdb":603}}}]"#)
            case "/upnext": return (200, [:], #"{"items":[{"show":{"ids":{"tmdb":1000}},"next_episode":{"season":2,"episode":6,"ids":{"tmdb":111112},"tvdb_ids":{"series":3000,"season":23,"episode":6}}}]}"#)
            default: return (500, [:], "{}")
            }
        }
        let records = try await MDBListTrackingClient(apiKey: key, session: session()).snapshot()
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.filter { $0.state == .watched }.count, 2)
        XCTAssertEqual(records.first { $0.state == .progress }?.runtime, 7200)
        XCTAssertEqual(records.first { $0.state == .upNext }?.target.tvdbSeason, 23)
        XCTAssertEqual(TrackingTestProtocol.requests.count, 5)
    }

    func testPartialAndMalformedSnapshotsRetainSavedHistory() async throws {
        let defaults = try defaults()
        let saved = MDBListTrackingRecord(target: movieTarget, state: .watched, progress: 100, updatedAt: Date())
        defaults.set(try JSONEncoder().encode([saved]), forKey: "Lineup.tracking.mdblistSnapshot.v1.7")
        TrackingTestProtocol.install { request in
            if request.url!.query!.contains("cursor=") { return (503, [:], "{}") }
            return (200, [:], #"{"movies":[],"pagination":{"next_cursor":"later"}}"#)
        }
        let service = MDBListTrackingService(defaults: defaults, session: session())
        defer { service.configure(accountID: nil, apiKey: nil, enabled: false) }
        service.configure(accountID: 7, apiKey: key, enabled: true)
        service.synchronize(force: true)
        try await eventually("failed second page retained cache") { service.status.contains("unavailable") }
        XCTAssertEqual(service.records, [saved])
        TrackingTestProtocol.install { _ in (200, [:], #"{"movies":[{"movie":{"ids":{"tmdb":603}}}],"episodes":[]}"#) }
        do { _ = try await MDBListTrackingClient(apiKey: key, session: session()).snapshot(); XCTFail("Missing watch date is not an empty bucket") }
        catch MDBListTrackingFailure.invalidResponse {} catch { XCTFail("Unexpected failure \(error)") }
    }

    func testSuccessfulEmptySnapshotClearsRemoteSnapshotOnly() async throws {
        let defaults = try defaults()
        let local = Data("local-sentinel".utf8)
        defaults.set(local, forKey: "Lineup.localMediaPlayback.v1")
        defaults.set(try JSONEncoder().encode([MDBListTrackingRecord(target: movieTarget, state: .watched,
            progress: 100, updatedAt: Date())]), forKey: "Lineup.tracking.mdblistSnapshot.v1.7")
        TrackingTestProtocol.install(Self.emptyResponse)
        let service = MDBListTrackingService(defaults: defaults, session: session())
        defer { service.configure(accountID: nil, apiKey: nil, enabled: false) }
        service.configure(accountID: 7, apiKey: key, enabled: true)
        service.synchronize(force: true)
        try await eventually("empty snapshot published") { service.lastSynced != nil }
        XCTAssertTrue(service.hasSnapshot)
        XCTAssertTrue(service.records.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "Lineup.localMediaPlayback.v1"), local)
    }

    func testEmptyRemoteSnapshotClearsWorkingLibraryWithoutTouchingSavedLocalProgress() async throws {
        TrackingTestProtocol.install(Self.emptyResponse)
        let defaults = try defaults()
        let (library, movie) = try makeLibrary(defaults)
        library.trackPlayback(of: movie, position: 420, duration: 3600)
        library.flushLocalPlayback()
        let saved = defaults.data(forKey: "Lineup.localMediaPlayback.v1")
        defaults.set(try JSONEncoder().encode([LocalMediaPlayback(profileID: movie.serverID!, item: movie,
            position: 900, duration: 3600, updatedAt: Date().addingTimeInterval(-600), completed: false)]),
            forKey: LibraryTrackingPreferences.cacheKey(7))
        library.setLocalTrackingEnabled(false)
        library.setMDBListTrackingEnabled(true)
        defer { library.setMDBListTrackingEnabled(false) }
        XCTAssertEqual(library.resumePosition(for: movie), 900)
        try await eventually("confirmed empty history clears MDB-only Library") {
            library.mdbListTracking.lastSynced != nil && library.localPlayback.isEmpty
        }
        XCTAssertNil(defaults.data(forKey: LibraryTrackingPreferences.cacheKey(7)))
        XCTAssertEqual(defaults.data(forKey: "Lineup.localMediaPlayback.v1"), saved)
        library.setLocalTrackingEnabled(true)
        XCTAssertEqual(library.resumePosition(for: movie), 420)
    }

    func testRateLimitKeepsDurableQueueWithoutRetriedRequestsOrCredentials() async throws {
        TrackingTestProtocol.install { _ in (429, ["Retry-After": "3600"], "{}") }
        let defaults = try defaults()
        let service = MDBListTrackingService(defaults: defaults, session: session())
        service.configure(accountID: 7, apiKey: key, enabled: true)
        service.enqueue(event(.pause))
        try await eventually("rate limit saved") { service.status.contains("waiting to retry") }
        service.flush(); service.synchronize(force: true)
        XCTAssertEqual(TrackingTestProtocol.requests.count, 1)
        let persisted = try XCTUnwrap(defaults.data(forKey: "Lineup.tracking.mdblistOutbox.v1.7"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(key))
        let restored = MDBListTrackingService(defaults: defaults, session: session())
        restored.configure(accountID: 7, apiKey: key, enabled: true)
        XCTAssertEqual(restored.pendingCount, 1)
        XCTAssertEqual(TrackingTestProtocol.requests.count, 1)
        restored.configure(accountID: nil, apiKey: nil, enabled: false)
        service.configure(accountID: nil, apiKey: nil, enabled: false)
    }

    func testAccountSwitchAndOptOutRetireQueuedWrites() async throws {
        TrackingTestProtocol.install { _ in (401, [:], "{}") }
        let defaults = try defaults()
        let service = MDBListTrackingService(defaults: defaults, session: session())
        service.configure(accountID: 7, apiKey: key, enabled: true)
        service.enqueue(event(.pause))
        try await eventually("credentials blocked") { service.status.contains("Reconnect") }
        service.configure(accountID: 8, apiKey: "different-test-key", enabled: true)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertNil(defaults.data(forKey: "Lineup.tracking.mdblistOutbox.v1.7"))
        service.enqueue(event(.stop))
        service.configure(accountID: nil, apiKey: nil, enabled: false)
        service.enqueue(event(.watched))
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertNil(defaults.data(forKey: "Lineup.tracking.mdblistOutbox.v1.8"))
    }

    func testExplicitSeriesMarkSupersedesOfflineEpisodeProgress() async throws {
        TrackingTestProtocol.install { _ in (429, ["Retry-After": "3600"], "{}") }
        let service = MDBListTrackingService(defaults: try defaults(), session: session())
        defer { service.configure(accountID: nil, apiKey: nil, enabled: false) }
        service.configure(accountID: 7, apiKey: key, enabled: true)
        let episode = MDBListTrackingTarget(kind: .episode, ids: ["tmdb": "1000"], season: 2, episode: 5)
        service.enqueue(event(.pause, session: UUID(), target: episode))
        try await eventually("offline progress saved") { service.status.contains("waiting") }
        service.enqueue(event(.watched, target: .init(kind: .show, ids: ["tmdb": "1000"])))
        XCTAssertEqual(service.pendingCount, 1)
    }

    func testMissingAcknowledgementIsRetriedInsteadOfLosingUpdate() async throws {
        TrackingTestProtocol.install { _ in (200, [:], "{}") }
        do { try await MDBListTrackingClient(apiKey: key, session: session()).write(event(.watched)); XCTFail("No acknowledgement") }
        catch MDBListTrackingFailure.invalidResponse {} catch { XCTFail("Unexpected \(error)") }
        TrackingTestProtocol.install { _ in (200, [:], #"{"updated":{},"not_found":{"movies":[{}]}}"#) }
        do { try await MDBListTrackingClient(apiKey: key, session: session()).write(event(.watched)); XCTFail("Unmatched title") }
        catch MDBListTrackingFailure.unavailable {} catch { XCTFail("Unexpected \(error)") }
    }
}

private final class TrackingTestProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], String)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var saved: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return saved }
    static var posts: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; saved = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Capture URLSession's body stream once, before it can be consumed.
        var captured = request
        captured.httpBody = try? request.trackingData()
        Self.lock.lock(); Self.saved.append(captured); let handler = Self.handler; Self.lock.unlock()
        do {
            let (status, headers, body) = try handler?(captured) ?? (500, [:], "{}")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private extension URLRequest {
    func trackingData() throws -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? NSError(domain: "body", code: 1) }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    func trackingBody() throws -> [String: Any] { try JSONSerialization.jsonObject(with: trackingData()) as? [String: Any] ?? [:] }
}
