import XCTest
@testable import LineupiOS

final class MobileGameReplayPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var teams: [MobileGameReplayPolicy.Team] {
        SportsTeamDirectory.bundled.teams(in: .nfl).map { .init($0.followedTeam) }
    }
    private var followed: Set<String> { Set(teams.filter { $0.value.abbreviation == "SF" }.map(\.value.id)) }

    func testOnlyMyTeamsShowsReplaysAndOtherLeagueFiltersHideThem() {
        XCTAssertTrue(MobileGameReplayPolicy.isVisible(myTeams: true, league: nil))
        XCTAssertTrue(MobileGameReplayPolicy.isVisible(myTeams: true, league: .nfl))
        for league in [SportsLeague.nba, .ncaaf, .soccer] {
            XCTAssertFalse(MobileGameReplayPolicy.isVisible(myTeams: true, league: league))
        }
        XCTAssertFalse(MobileGameReplayPolicy.isVisible(myTeams: false, league: .nfl))
        XCTAssertFalse(MobileGameReplayPolicy.isVisible(myTeams: false, league: nil))
    }

    func testRequestsOnlyArchiveEnabledNFLFeedsForFollowedTeamsOrGenericNFL() {
        XCTAssertEqual(teams.count, 32)
        XCTAssertEqual(followed.count, 1)
        let channels = [replayStream(1, "US: NFL San Francisco 49ers FHD"),
            replayStream(2, "NFL 01"), replayStream(3, "NFL Kansas City Chiefs"),
            replayStream(4, "NFL RedZone"), replayStream(5, "NFL 02", archive: false),
            replayStream(6, "NBA 01"), replayStream(7, "49ers", category: "nfl"),
            replayStream(8, "NFL College Football"), replayStream(9, "NFL 49ers Highlights")]
        let result = MobileGameReplayPolicy.candidates(streams: channels,
            categories: [.init(categoryID: "nfl", categoryName: "NFL Teams")], followed: followed, teams: teams)
        XCTAssertEqual(result.map(\.id), [1, 2, 7])
    }

    func testOnlyCompletedExplicitlyRecordedListingsWithinRetentionAreUsed() throws {
        let json = #"{"epg_listings":[{"title":"Recorded","start_timestamp":1799980000,"stop_timestamp":1799990000,"has_archive":1},{"title":"Not recorded","start_timestamp":1799980000,"stop_timestamp":1799990000,"has_archive":0},{"title":"No flag","start_timestamp":1799980000,"stop_timestamp":1799990000},{"title":"Still live","start_timestamp":1799999000,"stop_timestamp":1800001000,"has_archive":true},{"title":"Partly expired","start_timestamp":1799900000,"stop_timestamp":1799990000,"has_archive":"1"},{"title":"Broken","start_timestamp":1800000000,"stop_timestamp":1799990000,"has_archive":1}]}"#
        let table = try JSONDecoder().decode(XtreamArchiveTable.self, from: Data(json.utf8))
        XCTAssertEqual(table.confirmedGameRecordings(for: replayStream(1, "NFL", days: 1), now: now).map(\.title), ["Recorded"])
        XCTAssertTrue(table.confirmedGameRecordings(for: replayStream(1, "NFL", archive: false), now: now).isEmpty)
        // Unknown retention is not invented; explicit archive flags still apply.
        XCTAssertEqual(table.confirmedGameRecordings(for: replayStream(1, "NFL", days: 0), now: now).count, 2)
    }

    func testMatchesTheRecordedGameAndGroupsAlternateChannelsWithoutUsingTodaysSchedule() {
        let title = "NFL: San Francisco 49ers at Seattle Seahawks"
        let recordings = [recording(1, title), recording(2, title, offset: 60), recording(1, title),
            recording(3, "NFL Football", detail: "San Francisco 49ers vs Kansas City Chiefs"),
            recording(4, "Buffalo Bills vs Kansas City Chiefs"),
            recording(5, "San Francisco 49ers vs Seattle Seahawks Highlights"),
            recording(6, "NFL Football", detail: "News: San Francisco 49ers vs Seattle Seahawks"),
            recording(7, "NFL Football"), // A team channel alone isn't game identity.
            recording(8, "San Francisco 49ers vs Seattle Seahawks and Kansas City Chiefs"),
            recording(9, "NFL News", detail: "San Francisco 49ers vs Seattle Seahawks")]
        let result = MobileGameReplayPolicy.replays(recordings: recordings, followed: followed, teams: teams, now: now)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.flatMap(\.recordings).map(\.stream.id)), [1, 2, 3])
        XCTAssertEqual(result.first { $0.recordings.contains { $0.stream.id == 1 } }?.recordings.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.teams.count == 2 && $0.teams.contains { followed.contains($0.id) } })
        XCTAssertTrue(MobileGameReplayPolicy.replays(recordings: recordings, followed: [], teams: teams, now: now).isEmpty)
    }

    func testExpirationAndInvalidIntervalsCannotBeOffered() {
        let channel = replayStream(1, "NFL", days: 1)
        func program(_ start: Date, _ end: Date, streamID: Int = 1) -> CatchUpProgramme {
            .init(streamID: streamID, title: "49ers vs Seahawks", detail: "", start: start, end: end)
        }
        let valid = program(now.addingTimeInterval(-3600), now.addingTimeInterval(-60))
        XCTAssertTrue(MobileGameReplayPolicy.available(valid, stream: channel, now: now))
        XCTAssertFalse(MobileGameReplayPolicy.available(valid, stream: channel, now: now.addingTimeInterval(86400)))
        for invalid in [program(now, now.addingTimeInterval(60)), program(now, now),
                        program(now.addingTimeInterval(-90000), now.addingTimeInterval(-60)),
                        program(valid.start, valid.end, streamID: 999)] {
            XCTAssertFalse(MobileGameReplayPolicy.available(invalid, stream: channel, now: now))
        }
    }

    private func recording(_ id: Int, _ title: String, detail: String = "", offset: Double = 0) -> MobileGameReplayRecording {
        .init(stream: replayStream(id, "NFL 49ers"), program: .init(streamID: id, title: title, detail: detail,
            start: now.addingTimeInterval(-15000 + offset), end: now.addingTimeInterval(-5000 + offset)))
    }
}

@MainActor
final class MobileGameReplayStoreTests: XCTestCase {
    private var teams: [MobileGameReplayPolicy.Team] {
        SportsTeamDirectory.bundled.teams(in: .nfl).map { .init($0.followedTeam) }
    }
    private func request(profile: UUID = UUID(), enabled: Bool = true, playlist: Bool = false) -> MobileGameReplayStore.Request {
        .init(profileID: profile, playlist: playlist, refreshed: nil, channelCount: 7,
              followedIDs: teams.filter { $0.value.abbreviation == "SF" }.map(\.value.id), enabled: enabled)
    }

    func testConcurrencyIsBoundedAndCachedResultsSurviveLeavingMyTeams() async {
        let store = MobileGameReplayStore()
        let started = expectation(description: "three actual archive requests started")
        let fixture = ReplayFixture(onStart: { count in if count <= 3 { started.fulfill() } })
        started.expectedFulfillmentCount = 3
        let key = request()
        let channels = (1...7).map { replayStream($0, "NFL \($0)") }
        let task = Task { await store.load(key, streams: channels, categories: [], teams: teams) { try await fixture.fetch($0) } }
        await fulfillment(of: [started], timeout: 5)
        let before = await fixture.stats()
        XCTAssertEqual(before.calls, 3)
        XCTAssertEqual(before.maximum, 3)
        await fixture.releaseAll()
        await task.value
        let after = await fixture.stats()
        XCTAssertEqual(after.calls, 7)
        XCTAssertLessThanOrEqual(after.maximum, 3)
        XCTAssertFalse(store.loading)
        XCTAssertEqual(store.replays.count, 1)
        XCTAssertEqual(store.replays.first?.recordings.count, 7)
        await store.load(request(profile: key.profileID!, enabled: false), streams: channels, categories: [], teams: teams) { try await fixture.fetch($0) }
        XCTAssertTrue(store.replays.isEmpty)
        await store.load(key, streams: channels, categories: [], teams: teams) { try await fixture.fetch($0) }
        let cached = await fixture.stats()
        XCTAssertEqual(cached.calls, 7, "Returning to My Teams uses the short-lived account/channel cache")
        XCTAssertEqual(store.replays.first?.recordings.count, 7)
        await store.load(request(), streams: channels, categories: [], teams: teams) { try await fixture.fetch($0) }
        let switched = await fixture.stats()
        XCTAssertEqual(switched.calls, 14, "Another account must fetch its own archives even when channel IDs match")
    }

    func testCanceledOldProviderCannotReplaceNewProviderResults() async {
        let store = MobileGameReplayStore()
        let started = expectation(description: "old provider request really suspended")
        let old = ReplayFixture(onStart: { _ in started.fulfill() })
        let oldTask = Task { await store.load(request(), streams: [replayStream(1, "NFL")], categories: [], teams: teams) { try await old.fetch($0) } }
        await fulfillment(of: [started], timeout: 5)
        oldTask.cancel()
        store.cancel()
        let newer = ReplayFixture(released: true)
        let key = request()
        await store.load(key, streams: [replayStream(40, "NFL")], categories: [], teams: teams) { try await newer.fetch($0) }
        await old.releaseAll() // An uncooperative old request completes after the new one.
        await oldTask.value
        XCTAssertEqual(store.request, key)
        XCTAssertEqual(store.replays.flatMap(\.recordings).map(\.stream.id), [40])
        XCTAssertFalse(store.loading)
        XCTAssertEqual(store.failedChannels, 0)
    }

    func testPartialProviderFailurePreservesPlayableResultsAndRetryUsesTheCache() async {
        let store = MobileGameReplayStore()
        let fixture = ReplayFixture(released: true, fails: [2])
        let key = request()
        let streams = [replayStream(1, "NFL 01"), replayStream(2, "NFL 02")]
        await store.load(key, streams: streams, categories: [], teams: teams) { try await fixture.fetch($0) }
        XCTAssertEqual(store.failedChannels, 1)
        XCTAssertEqual(store.replays.flatMap(\.recordings).map(\.stream.id), [1])
        await store.load(key, streams: streams, categories: [], teams: teams) { try await fixture.fetch($0) }
        let stats = await fixture.stats()
        XCTAssertEqual(stats.calls, 3, "Only the failed channel is retried")
        XCTAssertEqual(store.replays.count, 1)
        store.clearCache()
        await store.load(key, streams: streams, categories: [], teams: teams) { try await fixture.fetch($0) }
        let refreshed = await fixture.stats()
        XCTAssertEqual(refreshed.calls, 5)
    }

    func testDisabledPlaylistMissingProfileAndNoFollowedTeamsNeverRequestArchives() async {
        let store = MobileGameReplayStore()
        var empty = request()
        empty = .init(profileID: empty.profileID, playlist: false, refreshed: nil, channelCount: 1, followedIDs: [], enabled: true)
        let missing = MobileGameReplayStore.Request(profileID: nil, playlist: false, refreshed: nil, channelCount: 1,
            followedIDs: request().followedIDs, enabled: true)
        for key in [request(enabled: false), request(playlist: true), empty, missing] {
            await store.load(key, streams: [replayStream(1, "NFL")], categories: [], teams: teams) { _ in
                XCTFail("This screen context must not request catch-up data")
                return []
            }
            XCTAssertFalse(store.loading)
            XCTAssertTrue(store.replays.isEmpty)
        }
    }

    func testReplayFailureReportsUnavailableInsteadOfOpeningLive() async throws {
        let suite = "MobileGameReplayTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = SportsLibrary(profileDefaults: defaults)
        let controller = MobilePlaybackController()
        defer { controller.shutdown() }
        let stream = replayStream(1, "NFL")
        let program = CatchUpProgramme(streamID: 1, title: "49ers vs Seahawks", detail: "",
            start: Date().addingTimeInterval(-15000), end: Date().addingTimeInterval(-5000))
        await controller.openRecording(of: stream, programme: program, from: library, requiresRecording: true)
        XCTAssertFalse(controller.loading)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.error, "This replay is no longer available. Refresh Game Replays and try again.")
    }
}

private func replayStream(_ id: Int, _ name: String, archive: Bool = true, days: Int = 7, category: String? = nil) -> XtreamStream {
    .init(num: nil, name: name, streamType: "live", streamID: id, streamIcon: nil,
          epgChannelID: nil, categoryID: category, tvArchive: archive, archiveDays: days)
}

private actor ReplayFixture {
    private var calls = 0
    private var active = 0
    private var maximum = 0
    private var released: Bool
    private let fails: Set<Int>
    private let onStart: @Sendable (Int) -> Void
    private var pending: [Int: CheckedContinuation<[CatchUpProgramme], Error>] = [:]
    private let start = Date().addingTimeInterval(-15000)
    init(released: Bool = false, fails: Set<Int> = [], onStart: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.released = released; self.fails = fails; self.onStart = onStart
    }
    func fetch(_ stream: XtreamStream) async throws -> [CatchUpProgramme] {
        calls += 1; active += 1; maximum = max(maximum, active)
        onStart(calls)
        if released {
            active -= 1
            if fails.contains(stream.id) { throw URLError(.cannotConnectToHost) }
            return programs(stream.id)
        }
        return try await withCheckedThrowingContinuation { pending[stream.id] = $0 }
    }
    func releaseAll() {
        released = true
        let waiting = pending
        pending.removeAll()
        active -= waiting.count
        for (id, continuation) in waiting { continuation.resume(returning: programs(id)) }
    }
    func stats() -> (calls: Int, maximum: Int) { (calls, maximum) }
    private func programs(_ id: Int) -> [CatchUpProgramme] {
        [.init(streamID: id, title: "San Francisco 49ers vs Seattle Seahawks", detail: "",
               start: start, end: start.addingTimeInterval(10000))]
    }
}
